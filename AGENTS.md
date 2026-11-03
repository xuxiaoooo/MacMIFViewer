# Development rules

- Keep MRXS direct preview explicitly scoped to the tested layout. Raw export and any claim of validated channel identity or coordinates require the S0 vendor-reference gate.
- Resolve channel and hierarchy metadata by name and validate index variants explicitly.
- Keep decoded components, display composites, and independently verified original pixels distinct.
- Read source slides only. Keep private data and diagnostic crops out of Git.
- Run the format, reader, and export regression tests relevant to each change.
