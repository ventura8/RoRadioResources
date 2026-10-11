# Copyright 2026 Sergiu Alexandrescu
"""Tests of scripts/captions/canary_dml_graph.py: which Reshapes it rewrites, and what it refuses."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "captions" / "canary_dml_graph.py"
_SPEC = importlib.util.spec_from_file_location("canary_dml_graph", SCRIPT)
canary_dml_graph = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(canary_dml_graph)


def reshape(name: str, data: str, shape: str, allowzero: int) -> onnx.NodeProto:
    """Return a Reshape node of data to shape with the given allowzero."""
    return helper.make_node("Reshape", [data, shape], [name + "_out"], name=name, allowzero=allowzero)


def model(nodes: list[onnx.NodeProto], initializers: list[onnx.TensorProto]) -> onnx.ModelProto:
    """Return a model over one float input x of shape [1, 6, 8] with the given nodes."""
    outputs = [
        helper.make_tensor_value_info(node.output[0], TensorProto.FLOAT, None)
        for node in nodes
        if node.op_type == "Reshape"
    ]
    graph = helper.make_graph(
        nodes,
        "test",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 6, 8])],
        outputs,
        initializer=initializers,
    )
    return helper.make_model(graph, opset_imports=[helper.make_opsetid("", 20)])


def shape(name: str, values: list[int]) -> onnx.TensorProto:
    """Return an int64 initializer."""
    return numpy_helper.from_array(np.array(values, dtype=np.int64), name)


def allowzero_of(graph_model: onnx.ModelProto, name: str) -> int:
    """Return the allowzero attribute of the named node."""
    node = next(node for node in graph_model.graph.node if node.name == name)
    return next(attribute.i for attribute in node.attribute if attribute.name == "allowzero")


class ClearAllowzeroTest(unittest.TestCase):
    """clear_allowzero changes only allowzero=1 Reshapes, and only where the change means nothing."""

    def test_constant_shapes_without_a_zero_are_rewritten(self) -> None:
        """A view with -1 in a constant shape loses allowzero; an allowzero=0 Reshape is left as it is."""
        graph_model = model(
            [reshape("view", "x", "s", 1), reshape("plain", "x", "s", 0)],
            [shape("s", [1, -1, 8])],
        )
        self.assertEqual(canary_dml_graph.clear_allowzero(graph_model), 1)
        self.assertEqual(allowzero_of(graph_model, "view"), 0)
        self.assertEqual(allowzero_of(graph_model, "plain"), 0)

    def test_a_constant_zero_in_the_shape_is_refused(self) -> None:
        """With a 0 in the shape, allowzero decides between an empty dimension and a copied one."""
        graph_model = model([reshape("view", "x", "s", 1)], [shape("s", [0, -1, 8])])
        with self.assertRaises(ValueError):
            canary_dml_graph.clear_allowzero(graph_model)

    def test_a_zero_among_the_constant_pieces_of_a_built_shape_is_refused(self) -> None:
        """A shape built with Concat is checked piece by piece: initializers and Constant nodes."""
        pieces = [
            helper.make_node("Shape", ["x"], ["full"], name="shape"),
            helper.make_node("Slice", ["full", "start", "end"], ["first"], name="slice"),
            helper.make_node(
                "Constant", [], ["zero"], name="const", value=numpy_helper.from_array(np.array([0], dtype=np.int64))
            ),
            helper.make_node("Concat", ["first", "zero", "eight"], ["built"], name="concat", axis=0),
        ]
        graph_model = model(
            [*pieces, reshape("view", "x", "built", 1)],
            [shape("start", [0]), shape("end", [1]), shape("eight", [8])],
        )
        with self.assertRaises(ValueError):
            canary_dml_graph.clear_allowzero(graph_model)

    def test_a_built_shape_without_a_constant_zero_is_rewritten(self) -> None:
        """Shape slices are never 0 for a non-empty tensor; constant pieces without a 0 are safe."""
        pieces = [
            helper.make_node("Shape", ["x"], ["full"], name="shape"),
            helper.make_node("Slice", ["full", "start", "end"], ["first"], name="slice"),
            helper.make_node("Concat", ["first", "minus", "eight"], ["built"], name="concat", axis=0),
        ]
        graph_model = model(
            [*pieces, reshape("view", "x", "built", 1)],
            [shape("start", [0]), shape("end", [1]), shape("minus", [-1]), shape("eight", [8])],
        )
        self.assertEqual(canary_dml_graph.clear_allowzero(graph_model), 1)


class MainTest(unittest.TestCase):
    """main writes the graph only for the pinned export's change count."""

    def setUp(self) -> None:
        """Write a two-view encoder-model.onnx into a temporary folder."""
        self.folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        graph_model = model(
            [reshape("a", "x", "s", 1), reshape("b", "x", "s", 1)],
            [shape("s", [1, -1, 8])],
        )
        onnx.save(graph_model, str(self.folder / "encoder-model.onnx"))

    def test_the_expected_count_writes_the_graph(self) -> None:
        """Two changes when two are expected: the output exists and carries allowzero=0."""
        with mock.patch.object(canary_dml_graph, "EXPECTED_CHANGES", 2), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(canary_dml_graph.main(self.folder, "out.onnx"), 0)
        written = onnx.load(str(self.folder / "out.onnx"))
        self.assertEqual(allowzero_of(written, "a"), 0)

    def test_another_count_writes_nothing(self) -> None:
        """Not the pinned export: exit 1 and no output file."""
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(canary_dml_graph.main(self.folder, "out.onnx"), 1)
        self.assertFalse((self.folder / "out.onnx").exists())


if __name__ == "__main__":
    unittest.main()
