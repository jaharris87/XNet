# Production build-system checks

Run the focused build-system checks from the repository root:

```bash
python3 test/build_system/test_build_system.py
```

The script builds the three direct products in a temporary GNU build directory,
checks generic host fallback, verifies configuration-reuse protection, and
verifies configuration-local cleaning.
