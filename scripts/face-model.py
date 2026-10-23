#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "coremltools==9.0", "numpy==2.5.4", "onnx==1.23.2", "onnx2torch==1.5.15", "onnxruntime==1.31.0",
#     "opencv-python==5.0.0.93", "pillow==13.0.0", "torch==2.7.0",
# ]
# ///
"""Makes the Core ML face models `digup faces-eval` reads for its Core ML engine (`CoreMLFaceEmbedder`), and checks
them.

    scripts/face-model.py convert <model> [--to DIR]            the model as Core ML, in DIR (default: DigUp's models
                                                                folder, faces/<its name>.mlpackage)
    scripts/face-model.py check <model> <picture or folder>...  the Core ML model against the ONNX it came from, on
                                                                the faces found in these pictures (20 or more): every
                                                                face's cosine must be 0.999 or more

The models, each a network that turns a face aligned to ArcFace's 112 x 112 template into one vector:

    sface      OpenCV Zoo's SFace (https://huggingface.co/opencv/face_recognition_sface): a MobileFaceNet, 128
               numbers. Apache-2.0, the code and the weights.
    lvface-b   ByteDance's LVFace-B, trained on Glint360K (https://huggingface.co/bytedance-research/LVFace, ICCV
               2025): a ViT-B, 512 numbers. The code is MIT, but the weights are for non-commercial research only.

Each ONNX takes the face's RGB values, SFace as they are (0-255, it scales them itself), LVFace scaled to -1-1; the
Core ML model takes a picture and does the same, so the engine only aligns the face. Another model is made the same
way when it takes one aligned face as a picture (its size is read from the model) and gives one vector.

The conversion goes ONNX -> PyTorch (onnx2torch) -> Core ML (coremltools), at float16 (the Neural Engine's) where
that keeps the ONNX's vectors (SFace; LVFace stays float32), and is checked on random input before it's kept. `check`
aligns faces as insightface and OpenCV do (the five points of OpenCV's YuNet detector, by least squares onto the
template) and compares Core ML with onnxruntime on the same crops. Run with uv (the versions above are pinned); the
downloads go to a temporary folder, deleted after. Prints counts and numbers, never file names.
"""
import argparse
import hashlib
import os
import sys
import tempfile
import urllib.request
from pathlib import Path
from typing import NamedTuple

import numpy as np


class Model(NamedTuple):
    onnx: tuple       # pinned: (url at a commit, SHA-256)
    name: str         # the Core ML model's file, in faces/
    scale: float      # how the ONNX takes a face's RGB values (0-255): value * scale + bias
    bias: float
    half: bool        # computed at float16, the Neural Engine's (else float32: GPU and processor)
    about: str        # the Core ML model's description


MODELS = {
    "sface": Model(
        ("https://huggingface.co/opencv/face_recognition_sface/resolve/3d7082438a6e4551e840c9b2bb60b71e8da4b524/"
         "face_recognition_sface_2021dec.onnx",
         "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"),
        "face_recognition_sface_2021dec.mlpackage", 1.0, 0.0, True,
        "SFace (OpenCV Zoo, Apache-2.0): a face aligned to ArcFace's 112 x 112 template, as RGB, to 128 numbers; "
        "compare two with cosine similarity"),
    "lvface-b": Model(
        ("https://huggingface.co/bytedance-research/LVFace/resolve/b12702ab1f5c721748e054a66dc90e1edd1f0724/"
         "LVFace-B_Glint360K/LVFace-B_Glint360K.onnx",
         "9d834ed8e927fd35b9123b2bf97c40aad05785b1f9ecfb1c4c1f6242d38d1382"),
        # At float16 its vectors came out as low as 0.998 from the ONNX's (72 real faces, 2026-10-22).
        "LVFace-B_Glint360K.mlpackage", 1 / 127.5, -1.0, False,
        "LVFace-B, Glint360K (ByteDance; weights for non-commercial research only): a face aligned to ArcFace's "
        "112 x 112 template, as RGB, to 512 numbers; compare two with cosine similarity"),
}
YUNET = ("https://huggingface.co/opencv/face_detection_yunet/resolve/3cc26e7f1014a5ee5d74a42acee58bafc9d0a310/"
         "face_detection_yunet_2023mar.onnx",
         "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4")
SIDE = 112
# ArcFace's five points in a 112 x 112 face (insightface's arcface_dst; Faces.arcFaceTemplate in DigUpKit).
TEMPLATE = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655],
                     [70.7299, 92.2041]])
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
    sha = hashlib.sha256()
    with open(path, "rb") as file:
        for piece in iter(lambda: file.read(1 << 23), b""):
            sha.update(piece)
    if sha.hexdigest() != digest:
        sys.exit(f"{path.name}: SHA-256 {sha.hexdigest()}, expected {digest}")
    return path


def cosine(a, b):
    a, b = np.ravel(a).astype(np.float64), np.ravel(b).astype(np.float64)
    return float(a @ b / np.linalg.norm(a) / np.linalg.norm(b))


def without_initializer_inputs(onnx_path):
    """The model, its weights not listed as graph inputs too: the SFace ONNX (an old MXNet export) lists them, and
    onnx2torch and onnxruntime want them as weights only."""
    import onnx

    model = onnx.load(onnx_path)
    weights = {w.name for w in model.graph.initializer}
    inputs = [i for i in model.graph.input if i.name not in weights]
    del model.graph.input[:]
    model.graph.input.extend(inputs)
    return model


def reference(session, model, rgb):
    """The ONNX's vector for an aligned face (112 x 112 x 3, RGB, 0-255), given as the model takes it."""
    pixels = rgb.transpose(2, 0, 1)[None].astype(np.float32) * model.scale + model.bias
    return session.run(None, {session.get_inputs()[0].name: pixels.astype(np.float32)})[0]


def convert(args):
    import coremltools as ct
    import onnx2torch
    import onnxruntime as ort
    import torch
    from PIL import Image

    model = MODELS[args.model]
    out = Path(args.to) if args.to else models_folder() / "faces" / model.name
    with tempfile.TemporaryDirectory() as work:
        onnx_model = without_initializer_inputs(download(model.onnx, work))
        traced = torch.jit.trace(onnx2torch.convert(onnx_model).eval(), torch.zeros(1, 3, SIDE, SIDE))
        converted = ct.convert(
            traced,
            inputs=[ct.ImageType(name="face", shape=(1, 3, SIDE, SIDE), color_layout=ct.colorlayout.RGB,
                                 scale=model.scale, bias=[model.bias] * 3)],
            outputs=[ct.TensorType(name="embedding")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16 if model.half else ct.precision.FLOAT32,
            minimum_deployment_target=ct.target.macOS14,
        )
        converted.short_description = model.about
        # Random pictures through both before it's kept (`check` does real faces).
        session = ort.InferenceSession(onnx_model.SerializeToString())
        rng = np.random.default_rng(0)
        for _ in range(8):
            rgb = rng.integers(0, 256, (SIDE, SIDE, 3), dtype=np.uint8)
            agreement = cosine(reference(session, model, rgb),
                               converted.predict({"face": Image.fromarray(rgb)})["embedding"])
            if agreement < AGREEMENT:
                sys.exit(f"the conversion disagrees with the ONNX on random input: cosine {agreement:.5f}")
        out.parent.mkdir(parents=True, exist_ok=True)
        converted.save(str(out))
    print(f"kept {out}")


def pictures(paths):
    for path in map(Path, paths):
        if path.is_dir():
            yield from sorted(p for p in path.rglob("*") if p.suffix.lower() in PICTURES)
        else:
            yield path


def aligned(image, points):
    """The face whose five points (YuNet's) are `points`, aligned to the template: the similarity that takes them
    closest to it, by least squares, as insightface and OpenCV align faces (outside the picture is black)."""
    import cv2

    source, target = points - points.mean(0), TEMPLATE - TEMPLATE.mean(0)
    spread = (source ** 2).sum()
    a = (source * target).sum() / spread
    b = (source[:, 0] * target[:, 1] - source[:, 1] * target[:, 0]).sum() / spread
    move = np.array([[a, -b, 0.0], [b, a, 0.0]])
    move[:, 2] = TEMPLATE.mean(0) - move[:, :2] @ points.mean(0)
    return cv2.warpAffine(image, move, (SIDE, SIDE), borderValue=0)


def check(args):
    import coremltools as ct
    import cv2
    import onnxruntime as ort
    from PIL import Image

    model = MODELS[args.model]
    converted = ct.models.MLModel(args.coreml or str(models_folder() / "faces" / model.name))
    agreement = []
    with tempfile.TemporaryDirectory() as work:
        session = ort.InferenceSession(without_initializer_inputs(download(model.onnx, work)).SerializeToString())
        detector = cv2.FaceDetectorYN.create(str(download(YUNET, work)), "", (320, 320), 0.8)
        for path in pictures(args.pictures):
            image = cv2.imread(str(path))
            if image is None:
                continue
            detector.setInputSize((image.shape[1], image.shape[0]))
            _, found = detector.detect(image)
            for face in found if found is not None else []:
                rgb = np.ascontiguousarray(aligned(image, face[4:14].reshape(5, 2))[:, :, ::-1])
                agreement.append(cosine(reference(session, model, rgb),
                                        converted.predict({"face": Image.fromarray(rgb)})["embedding"]))
            if args.limit and len(agreement) >= args.limit:
                break
    if not agreement:
        sys.exit("no faces found")
    print(f"{len(agreement)} faces: Core ML against onnxruntime, cosine min {min(agreement):.5f}, "
          f"mean {np.mean(agreement):.5f}")
    if len(agreement) < FACES_NEEDED or min(agreement) < AGREEMENT:
        sys.exit(f"not checked: needs {FACES_NEEDED} faces or more, each at {AGREEMENT} or more")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    making = commands.add_parser("convert")
    making.add_argument("model", choices=sorted(MODELS))
    making.add_argument("--to", help="where to keep the .mlpackage")
    checking = commands.add_parser("check")
    checking.add_argument("model", choices=sorted(MODELS))
    checking.add_argument("pictures", nargs="+")
    checking.add_argument("--coreml", help="the .mlpackage (default: the one `convert` keeps)")
    checking.add_argument("--limit", type=int, default=0, help="stop after this many faces")
    args = parser.parse_args()
    convert(args) if args.command == "convert" else check(args)


main()
