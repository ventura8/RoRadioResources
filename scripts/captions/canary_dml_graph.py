# Copyright 2026 Sergiu Alexandrescu
"""Write the DirectML graph of NVIDIA Canary-1B-v2's encoder for RoRadio's live captions.

DirectML 1.24 (Windows ML's ONNX Runtime) throws on the Reshape nodes of istupakov's ONNX export that carry
allowzero=1 (225 of 231; the first is node_view_189, error 0x8007023E), so the encoder could only run on the CPU.
allowzero only matters for a 0 in the target shape, and none of those Reshapes has one, so allowzero=0 means exactly
the same thing. This script rewrites only that attribute: the graph keeps pointing at the unchanged weights file
(encoder-model.onnx.data), and its output matches the CPU's to 3e-5.

It refuses to write anything unless the graph is the expected export: exactly EXPECTED_CHANGES Reshapes change, and
no constant piece of any of their target shapes is 0 (a shape built at run time is a Concat of constants and
Shape slices, which are never 0 for a non-empty tensor).

Usage: python scripts/captions/canary_dml_graph.py <folder with encoder-model.onnx> <output file name>
Needs the onnx package; the weights are not loaded.
"""

import sys
from pathlib import Path

import onnx
from onnx import numpy_helper

ARGUMENT_COUNT = 3  # the script, the folder and the output file name
EXPECTED_CHANGES = 225  # istupakov/canary-1b-v2-onnx at commit 5ebc1520cef7b6b318b3526ad17adbfe00bc1bfc


def constant_shape_values(model: onnx.ModelProto, name: str) -> list[int]:
    """Return the constant values of a Reshape's target shape: an initializer, or a Concat's constant inputs."""
    initializers = {tensor.name: tensor for tensor in model.graph.initializer}
    if name in initializers:
        return [int(value) for value in numpy_helper.to_array(initializers[name]).ravel()]
    producers = {output: node for node in model.graph.node for output in node.output}
    producer = producers.get(name)
    if producer is None or producer.op_type != "Concat":
        return []
    return [value for piece in producer.input for value in constant_shape_values_of_piece(model, piece, initializers)]


def constant_shape_values_of_piece(model: onnx.ModelProto, piece: str, initializers: dict) -> list[int]:
    """Return the values of one Concat input when it is a constant (an initializer or a Constant node)."""
    if piece in initializers:
        return [int(value) for value in numpy_helper.to_array(initializers[piece]).ravel()]
    for node in model.graph.node:
        if node.op_type == "Constant" and piece in node.output:
            return [int(value) for value in numpy_helper.to_array(node.attribute[0].t).ravel()]
    return []


def clear_allowzero(model: onnx.ModelProto) -> int:
    """Set allowzero=0 on every Reshape that has allowzero=1 and return how many there were.

    Raises ValueError when one of those Reshapes has a constant 0 in its target shape: there the attribute matters.
    """
    changed = 0
    for node in model.graph.node:
        if node.op_type != "Reshape":
            continue
        for attribute in node.attribute:
            if attribute.name == "allowzero" and attribute.i == 1:
                if 0 in constant_shape_values(model, node.input[1]):
                    message = f"{node.name} reshapes to a shape with a 0: allowzero changes its meaning there"
                    raise ValueError(message)
                attribute.i = 0
                changed += 1
    return changed


def main(folder: Path, output: str) -> int:
    """Rewrite encoder-model.onnx in folder into output next to it; return the process exit code."""
    model = onnx.load(str(folder / "encoder-model.onnx"), load_external_data=False)
    changed = clear_allowzero(model)
    if changed != EXPECTED_CHANGES:
        sys.stderr.write(f"expected {EXPECTED_CHANGES} allowzero=1 Reshapes, found {changed}: not the pinned export\n")
        return 1
    onnx.save(model, str(folder / output))
    sys.stdout.write(f"allowzero cleared on {changed} Reshape nodes; wrote {folder / output}\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != ARGUMENT_COUNT:
        sys.stderr.write(__doc__ or "")
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1]), sys.argv[2]))
