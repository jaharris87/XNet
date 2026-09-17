# Isolated build-graph effectiveness checks

Run the focused build-graph checks from the repository root:

```bash
python3 test/build_graph/test_build_graph.py
```

The script builds the three direct products in a temporary GNU build directory,
checks that production output contains no Python invocation, verifies a
configuration mismatch, and verifies configuration-local cleaning. It does not
claim unsupported same-directory concurrent invocations or automatic source
dependency discovery.
