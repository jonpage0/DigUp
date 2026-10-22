#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "coremltools==9.0", "numpy==2.5.4", "onnx==1.23.2", "onnx2torch==1.5.15", "onnxruntime==1.31.0",
#     "opencv-python==5.0.0.93", "pillow==13.0.0", "torch==2.7.0",
# ]
# ///
"""Makes the Core ML face model `digup faces-eval` reads for its Core ML engine (`CoreMLFaceEmbedder`), and checks it.

    scripts/face-model.py convert [--to DIR]            SFace as Core ML, in DIR (default: DigUp's models folder,
                                                        faces/face_recognition_sface_2021dec.mlpackage)
    scripts/face-model.py check <picture or folder>...  the Core ML model against the ONNX it came from, on the faces
                                                        found in these pictures (20 or more): every face's cosine must
                                                        be 0.999 or more

SFace is OpenCV Zoo's face recognizer (https://huggingface.co/opencv/face_recognition_sface, Apache-2.0 for the code
and the weights): a MobileFaceNet that turns a face aligned to ArcFace's 112 x 112 template into 128 numbers. The ONNX
takes the face as RGB, 0-255, and scales it itself, so the Core ML model takes a 112 x 112 RGB picture as it is: the
engine aligns the face, the model does the rest. Another model can be made the same way, as long as it takes one
aligned face as a picture (its size is read from the model) and gives one vector.

The conversion goes ONNX -> PyTorch (onnx2torch) -> Core ML (coremltools), at float16 (the Neural Engine's), and is
checked on random input before it's kept. `check` aligns faces as OpenCV does for SFace (its YuNet detector's five
points, FaceRecognizerSF.alignCrop) and compares Core ML with onnxruntime on the same crops. Run with uv (the versions
above are pinned); the downloads go to a temporary folder, deleted after. Prints counts and numbers, never file names.
"""
import argparse
import hashlib
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np

# Pinned: the Hugging Face mirrors of OpenCV Zoo, by commit, with the files' SHA-256.
SFACE = ("https://huggingface.co/opencv/face_recognition_sface/resolve/3d7082438a6e4551e840c9b2bb60b71e8da4b524/"
         "face_recognition_sface_2021dec.onnx",
         "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79")
YUNET = ("https://huggingface.co/opencv/face_detection_yunet/resolve/3cc26e7f1014a5ee5d74a42acee58bafc9d0a310/"
         "face_detection_yunet_2023mar.onnx",
         "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4")
NAME = "face_recognition_sface_2021dec.mlpackage"
SIDE = 112
AGREEMENT = 0.999
FACES_NEEDED = 20
PICTURES = (".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff")


def models_folder():
    """DigUp's models folder: $DIGUP_MODELS, else ~/Library/Application Support/DigUp/Models
    (`ModelFiles.installed`)."""
    chosen = os.environ.get("DIGUP_MODELS")
    return Path(chosen) if chosen else Path.home() / "Library/Application Support/DigUp/Models"


def download(pinned, folder):
    url, digest = pinned
    path = Path(folder) / url.rsplit("/", 1)[1]
    urllib.request.urlretrieve(url, path)
    found = hashlib.sha256(path.read_bytes()).hexdigest()
    if found != digest:
        sys.exit(f"{path.name}: SHA-256 {found}, expected {digest}")
    return path


def cosine(a, b):
    a, b = np.ravel(a).astype(np.float64), np.ravel(b).astype(np.float64)
    return float(a @ b / np.linalg.norm(a) / np.linalg.norm(b))


def without_initializer_inputs(onnx_path):
    """The SFace ONNX (an old MXNet export) lists its weights as graph inputs too; onnx2torch and onnxruntime want
    them as weights only."""
    import onnx

    model = onnx.load(onnx_path)
    weights = {w.name for w in model.graph.initializer}
    inputs = [i for i in model.graph.input if i.name not in weights]
    del model.graph.input[:]
    model.graph.input.extend(inputs)
    return model


def convert(args):
    import coremltools as ct
    import onnx2torch
    import onnxruntime as ort
    import torch

    out = Path(args.to) if args.to else models_folder() / "faces" / NAME
    with tempfile.TemporaryDirectory() as work:
        onnx_model = without_initializer_inputs(download(SFACE, work))
        network = onnx2torch.convert(onnx_model).eval()
        example = torch.zeros(1, 3, SIDE, SIDE)
        traced = torch.jit.trace(network, example)
        model = ct.convert(
            traced,
            inputs=[ct.ImageType(name="face", shape=(1, 3, SIDE, SIDE), color_layout=ct.colorlayout.RGB, scale=1.0,
                                 bias=[0, 0, 0])],
            outputs=[ct.TensorType(name="embedding")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS14,
        )
        model.short_description = ("SFace (OpenCV Zoo, Apache-2.0): a face aligned to ArcFace's 112 x 112 template, "
                                   "as RGB, to 128 numbers; compare two with cosine similarity")
        # Random pictures through both before it's kept (`check` does real faces).
        from PIL import Image

        session = ort.InferenceSession(onnx_model.SerializeToString())
        rng = np.random.default_rng(0)
        for _ in range(8):
            pixels = rng.integers(0, 256, (SIDE, SIDE, 3), dtype=np.uint8)
            reference = session.run(None, {"data": pixels.transpose(2, 0, 1)[None].astype(np.float32)})[0]
            converted = model.predict({"face": Image.fromarray(pixels)})["embedding"]
            agreement = cosine(reference, converted)
            if agreement < AGREEMENT:
                sys.exit(f"the conversion disagrees with the ONNX on random input: cosine {agreement:.5f}")
        out.parent.mkdir(parents=True, exist_ok=True)
        model.save(str(out))
    print(f"kept {out}")


def pictures(paths):
    for path in map(Path, paths):
        if path.is_dir():
            yield from sorted(p for p in path.rglob("*") if p.suffix.lower() in PICTURES)
        else:
            yield path


def check(args):
    import coremltools as ct
    import cv2
    import onnxruntime as ort
    from PIL import Image

    model = ct.models.MLModel(args.model or str(models_folder() / "faces" / NAME))
    agreement, faces = [], 0
    with tempfile.TemporaryDirectory() as work:
        onnx_path = download(SFACE, work)
        session = ort.InferenceSession(without_initializer_inputs(onnx_path).SerializeToString())
        detector = cv2.FaceDetectorYN.create(str(download(YUNET, work)), "", (320, 320), 0.8)
        aligner = cv2.FaceRecognizerSF.create(str(onnx_path), "")
        for path in pictures(args.pictures):
            image = cv2.imread(str(path))
            if image is None:
                continue
            detector.setInputSize((image.shape[1], image.shape[0]))
            _, found = detector.detect(image)
            for face in found if found is not None else []:
                crop = aligner.alignCrop(image, face)                   # 112 x 112, BGR
                rgb = np.ascontiguousarray(crop[:, :, ::-1])
                reference = session.run(None, {"data": rgb.transpose(2, 0, 1)[None].astype(np.float32)})[0]
                converted = model.predict({"face": Image.fromarray(rgb)})["embedding"]
                agreement.append(cosine(reference, converted))
                faces += 1
            if args.limit and faces >= args.limit:
                break
    if not agreement:
        sys.exit("no faces found")
    print(f"{faces} faces: Core ML against onnxruntime, cosine min {min(agreement):.5f}, mean {np.mean(agreement):.5f}")
    if faces < FACES_NEEDED or min(agreement) < AGREEMENT:
        sys.exit(f"not checked: needs {FACES_NEEDED} faces or more, each at {AGREEMENT} or more")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    making = commands.add_parser("convert")
    making.add_argument("--to", help="where to keep the .mlpackage")
    checking = commands.add_parser("check")
    checking.add_argument("pictures", nargs="+")
    checking.add_argument("--model", help="the .mlpackage (default: the one `convert` keeps)")
    checking.add_argument("--limit", type=int, default=0, help="stop after this many faces")
    args = parser.parse_args()
    convert(args) if args.command == "convert" else check(args)


main()
