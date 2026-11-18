# Changelog

## [0.2.0](https://github.com/flashpi1/flashpi-ruby/compare/v0.1.0...v0.2.0) (2026-11-18)


### Features

* **types:** let the last payment leave out its amount ([2eb013a](https://github.com/flashpi1/flashpi-ruby/commit/2eb013a5d74253ccf249424d087d9551f1ef9881))

## 0.1.0 (2026-11-14)


### Features

* add the client and every API operation ([c267d7c](https://github.com/flashpi1/flashpi-ruby/commit/c267d7c83cadbc1a3c5c2f9696db58dee6c7b5fd))
* add the errors ([542b470](https://github.com/flashpi1/flashpi-ruby/commit/542b4703900d3e5ba426a49c2456d63ac9801c7e))
* add the request engine and its net/http transport ([cb83b6f](https://github.com/flashpi1/flashpi-ruby/commit/cb83b6f04e4e08197c59bedae824b8b385f624a5))
* generate RBS types from the OpenAPI contract ([e590c97](https://github.com/flashpi1/flashpi-ruby/commit/e590c97a6c39af50a1cc7495ed0268d6570a8e3f))
* type the gem with RBS signatures checked by Steep ([7b73fab](https://github.com/flashpi1/flashpi-ruby/commit/7b73fab55389e6dc438ae8c04da87714da883d5d))
* verify the webhooks Flashpi sends ([338c0fb](https://github.com/flashpi1/flashpi-ruby/commit/338c0fbf9885c45731df9a51ea2c05e242ceffc7))


### Bug fixes

* check ids, filters and certificate fields as UTF-8 text ([8ec57d7](https://github.com/flashpi1/flashpi-ruby/commit/8ec57d7a3702b379544b47b0eaa7da87d5c5775e))
* **ci:** name the owning account when the release exchanges its token ([c36e333](https://github.com/flashpi1/flashpi-ruby/commit/c36e333ff67cf080f71b90e3cfa8e09ed0bfb9f0))
* end every bad webhook in a WebhookVerificationError ([3ef3ba7](https://github.com/flashpi1/flashpi-ruby/commit/3ef3ba7997f8bbcff10c07884bf57daf039f95a6))
* harden the transport's proxies, truncated answers and kept-alive connections ([387a725](https://github.com/flashpi1/flashpi-ruby/commit/387a725c47ce17e90148b06e2e7e1999ac8f7ec8))
* keep a failed upload's .p12 and password out of the engine's locals ([1dc5853](https://github.com/flashpi1/flashpi-ruby/commit/1dc5853993a60100c4e524ff7fe2abb7e8c1fdaa))
* let a StopIteration of the caller's block through Page#each ([4910a1c](https://github.com/flashpi1/flashpi-ruby/commit/4910a1c8a7bd7f7fb5eb902af3a2c392b6355866))
* **scripts:** type path-level parameters and refuse serialization settings ([4e6a5e6](https://github.com/flashpi1/flashpi-ruby/commit/4e6a5e6ff587c9850b6287eca136d9f3a11adc75))
* send a POST without a body with no Content-Type on Ruby 3.3 and 3.4 ([d3f6888](https://github.com/flashpi1/flashpi-ruby/commit/d3f6888a6a2ae56a324616384304c604090a22b6))
