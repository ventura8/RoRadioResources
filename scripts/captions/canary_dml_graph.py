# Copyright 2026 Sergiu Alexandrescu
"""Write the DirectML graph of NVIDIA Canary-1B-v2's encoder for RoRadio's live captions.

DirectML 1.24 (Windows ML's ONNX Runtime) throws on the Reshape nodes of istupakov's ONNX export that carry
allowzero=1 (225 of 231; the first is node_view_189, error 0x8007023E), so the encoder could only run on the CPU.
None of those Reshapes has a literal 0 in its shape, so allowzero=0 means exactly the same thing. This script
rewrites only that attribute: the graph keeps pointing at the unchanged weights file (encoder-model.onnx.data), and
its output matches the CPU's to 3e-5.

Usage: python scripts/captions/canary_dml_graph.py <folder with encoder-model.onnx> <output file name>
Needs the onnx package; the weights are not loaded.
"""

import sys
from pathlib import Path

import onnx

ARGUMENT_COUNT = 3  # the script, the folder and the output file name


def clear_allowzero(model: onnx.ModelProto) -> int:
    """Set allowzero=0 on every Reshape that has allowzero=1 and return how many there were."""
    changed = 0
    for node in model.graph.node:
        if node.op_type != "Reshape":
            continue
        for attribute in node.attribute:
            if attribute.name == "allowzero" and attribute.i == 1:
                attribute.i = 0
                changed += 1
    return changed


def main(folder: Path, output: str) -> int:
    """Rewrite encoder-model.onnx in folder into output next to it; return the process exit code."""
    model = onnx.load(str(folder / "encoder-model.onnx"), load_external_data=False)
    changed = clear_allowzero(model)
    onnx.save(model, str(folder / output))
    sys.stdout.write(f"allowzero cleared on {changed} Reshape nodes; wrote {folder / output}\n")
    return 0 if changed else 1


if __name__ == "__main__":
    if len(sys.argv) != ARGUMENT_COUNT:
        sys.stderr.write(__doc__ or "")
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1]), sys.argv[2]))
