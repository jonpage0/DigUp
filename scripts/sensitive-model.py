#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "coremltools==9.0", "numpy==2.5.4", "pillow==13.0.0", "pillow-heif==1.8.1", "safetensors==0.8.0",
#     "timm==1.0.30", "torch==2.7.0", "torchvision==0.22.0",
# ]
# ///
"""Makes the Core ML model DigUp rates pictures with (`SensitiveModel`, "Blur sensitive pictures" and the Sensitive
filter), and checks it against the PyTorch model it came from.

    scripts/sensitive-model.py convert [--to DIR]                the model as Core ML, in DIR (default: DigUp's models
                                                                 folder, sensitive/)
    scripts/sensitive-model.py check <picture or folder>...      the Core ML model against PyTorch on these pictures
                [--most N] [--digup PATH]                        (300 or more): each level's probability within 0.01,
                                                                 and the three settings' decisions the same on 99.5 %;
                                                                 with --digup the app's own path too, its decisions
                                                                 the same on 99.5 %

The model is Freepik's nsfw_image_detector (https://huggingface.co/Freepik/nsfw_image_detector, MIT): an EVA02-base
at 448 x 448 pixels, fine-tuned from timm's eva02_base_patch14_448.mim_in22k_ft_in22k_in1k to say how revealing a
picture is, as the probability of four levels: neutral, low (swimwear, lingerie, implied nudity), medium and high
(explicit). ADULT-CONTENT-EVAL.md (2026-10-22) chose it over five others on a real library.

Its own preprocessing, as its card and its config say (timm's eval transform for it): the picture squashed to 448 x 448
(each side scaled, its proportions not kept), bicubic, then each RGB value as a fraction (0-1) less CLIP's mean, over
CLIP's deviation. The Core ML model takes the squashed picture and does the rest itself, and gives the four
probabilities (softmax), so DigUp only scales the picture. The weights and config are pinned (a commit and SHA-256s),
and the converted model records which in its metadata (`digup.revision`, `digup.conversion`), which DigUp checks: a
model that isn't this conversion of this commit isn't used.

The conversion goes PyTorch (timm) -> Core ML (coremltools) at `PRECISION`, checked on random input before it's kept,
and kept compiled (.mlmodelc, what DigUp loads). `check` reads each picture upright (its EXIF orientation applied),
squashes it with the model's own transform, and gives the same pixels to PyTorch (float32, on the processor) and to the
kept Core ML model: the conversion, held to each level within `MAX_DIFFERENCE` and each setting's decision the same on
`AGREEMENT`. With `--digup`, the app's own path too, told apart (`digup sensitive`: the picture as indexing writes it
for the model, a JPEG of 1,024 pixels at most, a screenshot a PNG of 1,536, read by ImageIO, squashed by Core Graphics
and rated by Core ML). It doesn't start from the same pixels, so its levels can move more than the conversion's: it's
held to each setting's decision the same on `AGREEMENT`, and its largest differences are said. Either one short of its
bar fails the check. A file that's only in iCloud (dataless) is never opened. Run with uv (the versions above are
pinned); the downloads go to a temporary folder, deleted after. Prints counts and numbers, never file names.
"""
import argparse
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np

REPOSITORY = "Freepik/nsfw_image_detector"
REVISION = "15b85477e4fd2000db76ae9aae0f89a72f95e2e3"
# Pinned: (file at REVISION, SHA-256).
CONFIG = ("config.json", "39f53e86cc4868e0e11396b523c906f376621f54c1025ffc9ee2ee840542a41b")
WEIGHTS = ("model.safetensors", "024a9d4818fae2656403bf626c9f8c9e7789c2da274749fbebb1060d8fdaa7ab")
# The conversion's version, which DigUp's index records with the model (`fork_sensitive_model`): a change to how the
# model is made that can move its numbers is a new one, and every picture is rated again.
CONVERSION = 1
# The Core ML model's file in sensitive/ (`SensitiveModel.model`), named for the commit and the conversion.
NAME = f"nsfw_image_detector-{REVISION[:7]}-c{CONVERSION}.mlmodelc"
SIDE = 448
LEVELS = ["neutral", "low", "medium", "high"]
# At float16 (the Neural Engine's) a level came out up to 0.0143 from PyTorch's (493 pictures, 2026-10-22: the test
# libraries and Jon's library, every setting's decision the same), past `MAX_DIFFERENCE`: it stays float32.
PRECISION = "float32"
# DigUp runs it on the GPU (`CoreMLSensitiveRater.computeUnits`), and so is it checked.
COMPUTE = "CPU_AND_GPU"
# The settings' positions (`SensitivePosition`): the levels summed from the lowest one named, at least this much.
RULES = [("anything revealing", 1, 0.2), ("revealing", 1, 0.5), ("nudity only", 2, 0.5)]
MAX_DIFFERENCE = 0.01
AGREEMENT = 0.995
PICTURES_NEEDED = 300
PICTURES = (".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff", ".webp", ".gif")
# A file whose contents are only in iCloud: opening it would download it (SF_DATALESS).
DATALESS = 0x40000000


def models_folder():
    """DigUp's models folder: $DIGUP_MODELS, else ~/Library/Application Support/DigUp/Models
    (`ModelFiles.installed`)."""
    chosen = os.environ.get("DIGUP_MODELS")
    return Path(chosen) if chosen else Path.home() / "Library/Application Support/DigUp/Models"


def download(pinned, folder):
    name, digest = pinned
    path = Path(folder) / name
    urllib.request.urlretrieve(f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}", path)
    sha = hashlib.sha256()
    with open(path, "rb") as file:
        for piece in iter(lambda: file.read(1 << 23), b""):
            sha.update(piece)
    if sha.hexdigest() != digest:
        sys.exit(f"{name}: SHA-256 {sha.hexdigest()}, expected {digest}")
    return path


class Levels:
    """The PyTorch model as its card runs it, in float32: its config, its weights, and its transform."""

    def __init__(self, folder):
        import safetensors.torch
        import timm
        import torch
        from timm.data import resolve_data_config
        from timm.data.transforms_factory import create_transform

        config = json.loads(download(CONFIG, folder).read_text())
        cfg = config["pretrained_cfg"]
        # What `Wrapped` and DigUp do, checked against what the config says.
        if (config["label_names"] != LEVELS or cfg["input_size"] != [3, SIDE, SIDE] or cfg["crop_mode"] != "squash"
                or cfg["crop_pct"] != 1.0 or cfg["interpolation"] != "bicubic"):
            sys.exit("the model's config isn't the one this script was written for")
        self.mean, self.std = cfg["mean"], cfg["std"]
        model = timm.create_model(config["architecture"], pretrained=False, num_classes=config["num_classes"],
                                  global_pool=config["global_pool"])
        # Its weights are the transformers wrapper's (TimmWrapperForImageClassification): timm's, under timm_model.
        weights = safetensors.torch.load_file(download(WEIGHTS, folder))
        model.load_state_dict({key.removeprefix("timm_model."): value for key, value in weights.items()})
        self.model = model.float().eval()
        transform = create_transform(**resolve_data_config(cfg))
        steps = transform.transforms
        # Squash, crop (nothing to crop at 1.0), to a tensor, normalize: the first two on the picture, the rest here.
        if len(steps) != 4 or type(steps[0]).__name__ != "Resize" or type(steps[1]).__name__ != "CenterCrop":
            sys.exit(f"timm's transform isn't the one this script was written for: {transform}")
        self.squash = lambda picture: steps[1](steps[0](picture))
        self.tensor = lambda squashed: steps[3](steps[2](squashed))
        self.torch = torch

    def __call__(self, squashed):
        """The four levels' probabilities for squashed pictures (448 x 448 RGB), as an array of N x 4."""
        with self.torch.inference_mode():
            batch = self.torch.stack([self.tensor(picture) for picture in squashed])
            return self.torch.softmax(self.model(batch), dim=-1).numpy().astype(np.float64)


def wrapped(levels):
    """The model as Core ML takes it: a picture's RGB values as fractions (0-1), normalized here, and the levels'
    probabilities out."""
    import torch

    class Wrapped(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = levels.model
            self.register_buffer("mean", torch.tensor(levels.mean).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(levels.std).view(1, 3, 1, 1))

        def forward(self, picture):
            return torch.softmax(self.model((picture - self.mean) / self.std), dim=-1)

    return Wrapped().eval()


def convert(args):
    import coremltools as ct
    import torch
    from PIL import Image

    out = Path(args.to) if args.to else models_folder() / "sensitive" / NAME
    with tempfile.TemporaryDirectory() as work:
        levels = Levels(work)
        traced = torch.jit.trace(wrapped(levels), torch.zeros(1, 3, SIDE, SIDE))
        converted = ct.convert(
            traced,
            inputs=[ct.ImageType(name="picture", shape=(1, 3, SIDE, SIDE), color_layout=ct.colorlayout.RGB,
                                 scale=1 / 255.0, bias=[0.0, 0.0, 0.0])],
            outputs=[ct.TensorType(name="levels")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16 if PRECISION == "float16" else ct.precision.FLOAT32,
            minimum_deployment_target=ct.target.macOS14,
        )
        converted.short_description = (
            "Freepik's nsfw_image_detector (EVA02-base 448, MIT): a picture squashed to 448 x 448, as RGB, to the "
            "probability of each level of revealing content: " + ", ".join(LEVELS))
        converted.author = "Freepik Company S.L. (the model); scripts/sensitive-model.py (the conversion)"
        converted.license = "MIT"
        converted.user_defined_metadata.update({
            "digup.model": REPOSITORY, "digup.revision": REVISION, "digup.conversion": str(CONVERSION),
            "digup.levels": ",".join(LEVELS), "digup.precision": PRECISION})
        # Random pictures through both before it's kept (`check` does real ones).
        rng = np.random.default_rng(0)
        for _ in range(4):
            picture = Image.fromarray(rng.integers(0, 256, (SIDE, SIDE, 3), dtype=np.uint8))
            difference = np.abs(levels([picture])[0] - converted.predict({"picture": picture})["levels"][0]).max()
            if difference > MAX_DIFFERENCE:
                sys.exit(f"the conversion disagrees with PyTorch on random input: {difference:.4f}")
        package = Path(work) / "model.mlpackage"
        converted.save(str(package))
        compiled = Path(ct.utils.compile_model(str(package)))
        out.parent.mkdir(parents=True, exist_ok=True)
        if out.exists():
            shutil.rmtree(out)
        shutil.move(str(compiled), out)
    print(f"kept {out} ({PRECISION}, conversion {CONVERSION} of {REPOSITORY} at {REVISION[:7]})")


def pictures(paths, most, seed):
    """The pictures under each path, at most `most` of each folder's, drawn at random; with how many were left out
    because they're only in iCloud."""
    found, dataless = [], 0
    for path in map(Path, paths):
        here = sorted(p for p in path.rglob("*") if p.suffix.lower() in PICTURES) if path.is_dir() else [path]
        kept = []
        for picture in here:
            try:
                if picture.stat().st_flags & DATALESS:
                    dataless += 1
                    continue
            except OSError:
                continue
            kept.append(picture)
        if most and len(kept) > most:
            kept = random.Random(seed).sample(kept, most)
        found += kept
    return found, dataless


def upright(path):
    """The picture as it's shown (its EXIF orientation applied), in RGB; None when it can't be read."""
    from PIL import Image, ImageOps

    try:
        with Image.open(path) as picture:
            return ImageOps.exif_transpose(picture).convert("RGB")
    except Exception:
        return None


def app_levels(digup, paths):
    """`digup sensitive --json` on these pictures: each one's levels as the app reads them, by path, and the
    milliseconds each took (reading the picture and rating it)."""
    run = subprocess.run([digup, "sensitive", "--json", *map(str, paths)], capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit(f"digup sensitive failed: {run.stderr.strip()[-400:]}")
    rated, times = {}, []
    for line in run.stdout.splitlines():
        row = json.loads(line)
        if "levels" in row:
            rated[row["path"]] = np.array([row["levels"][level] for level in LEVELS])
            times.append(row["ms"])
    return rated, times


def report(name, reference, other, max_difference=None):
    """Each level's largest difference and each setting's agreement; whether they're within the bar: each setting the
    same on `AGREEMENT` or more and, with `max_difference`, each level within it."""
    difference = np.abs(reference - other).max(axis=0)
    print(f"{name}: {len(reference)} pictures; largest difference "
          + ", ".join(f"{level} {difference[i]:.5f}" for i, level in enumerate(LEVELS)))
    good = max_difference is None or bool(difference.max() <= max_difference)
    for rule, lowest, threshold in RULES:
        torch_says = reference[:, lowest:].sum(axis=1) >= threshold
        other_says = other[:, lowest:].sum(axis=1) >= threshold
        agreement = float((torch_says == other_says).mean())
        good = good and agreement >= AGREEMENT
        print(f"  {rule} (≥ {threshold} from {LEVELS[lowest]}): flagged {int(torch_says.sum())} by PyTorch, "
              f"{int(other_says.sum())} here; the same on {agreement:.2%} ({int((torch_says != other_says).sum())} "
              "differ)")
    bar = (f"each level within {max_difference}, " if max_difference is not None else "") + \
        f"each setting the same on {AGREEMENT:.1%} or more"
    print(f"  {'within' if good else 'NOT within'} its bar: {bar}")
    return good


def check(args):
    import coremltools as ct
    from pillow_heif import register_heif_opener

    register_heif_opener()
    coreml = Path(args.coreml) if args.coreml else models_folder() / "sensitive" / NAME
    converted = ct.models.CompiledMLModel(str(coreml), compute_units=getattr(ct.ComputeUnit, COMPUTE))
    found, dataless = pictures(args.pictures, args.most, args.seed)
    reference, ours, read = [], [], []
    unreadable = 0
    with tempfile.TemporaryDirectory() as work:
        levels = Levels(work)
        for path in found:
            picture = upright(path)
            if picture is None:
                unreadable += 1
                continue
            squashed = levels.squash(picture)
            reference.append(levels([squashed])[0])
            ours.append(np.array(converted.predict({"picture": squashed})["levels"][0], dtype=np.float64))
            read.append(path)
    print(f"{len(read)} pictures read ({unreadable} PIL can't read, {dataless} only in iCloud left alone)")
    if not read:
        sys.exit("no pictures")
    reference, ours = np.array(reference), np.array(ours)
    checks = [("the conversion", report(f"Core ML ({PRECISION}, {COMPUTE}), the same pixels as PyTorch", reference,
                                        ours, MAX_DIFFERENCE))]
    if args.digup:
        rated, times = app_levels(args.digup, read)
        both = [i for i, path in enumerate(read) if str(path) in rated]
        print(f"digup sensitive (the app's path): {len(both)} of them rated, {np.median(times):.0f} ms a picture "
              f"(median; p90 {np.percentile(times, 90):.0f} ms), reading it included")
        checks.append(("the app's path", bool(both) and report(
            "the app's path, from the picture as indexing writes it", reference[both],
            np.array([rated[str(read[i])] for i in both]))))
    short = [name for name, good in checks if not good]
    if len(read) < PICTURES_NEEDED or short:
        sys.exit("not checked: " + "; ".join(
            ([f"needs {PICTURES_NEEDED} pictures or more"] if len(read) < PICTURES_NEEDED else [])
            + [f"{name} isn't within its bar" for name in short]))
    print("checked: " + " and ".join(name for name, _ in checks))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    making = commands.add_parser("convert")
    making.add_argument("--to", help="where to keep the .mlmodelc")
    checking = commands.add_parser("check")
    checking.add_argument("pictures", nargs="+")
    checking.add_argument("--coreml", help="the .mlmodelc (default: the one `convert` keeps)")
    checking.add_argument("--most", type=int, default=0, help="at most this many pictures of each folder, at random")
    checking.add_argument("--seed", type=int, default=0, help="which pictures --most draws")
    checking.add_argument("--digup", help="a digup helper: check the app's own path too")
    args = parser.parse_args()
    convert(args) if args.command == "convert" else check(args)


main()
