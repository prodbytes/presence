# TensorFlow.js

Subject recognition's runtime on web
([lib/recognition/runtime_web.dart](../../lib/recognition/runtime_web.dart)),
served with the app and loaded the first time a model is. Copied from npm,
unmodified:

| File | Package |
|---|---|
| `tf-core.min.js` | `@tensorflow/tfjs-core@4.22.0` (`dist/`) |
| `tf-backend-cpu.min.js` | `@tensorflow/tfjs-backend-cpu@4.22.0` (`dist/`) |
| `tf-tflite.min.js` | `@tensorflow/tfjs-tflite@0.0.1-alpha.10` (`dist/`) |
| `tflite_web_api_cc*.js`, `.wasm` | `@tensorflow/tfjs-tflite@0.0.1-alpha.10` (`wasm/`; the SIMD build and the plain fallback) |

All Apache-2.0. The threaded builds are left out: they need the page to be
cross-origin isolated.
