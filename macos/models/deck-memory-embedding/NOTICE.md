# The model behind Terminal Deck's search by meaning

`gte-small.mlmodelc` is **gte-small** (General Text Embeddings, small; 33 million parameters, 384-number vectors),
converted to Core ML on 11 Oct 2026 with its weights stored as 8-bit integers (computation in 16-bit floats), mean
pooling and L2 normalisation built in. `vocab.txt` is the model's own WordPiece vocabulary (30,522 entries, the
uncased BERT vocabulary it was trained with).

- Source: https://huggingface.co/thenlper/gte-small, revision 17e1f347d17fe144873b1201da91788898c639cd
- Paper: Zehan Li, Xin Zhang, Yanzhao Zhang, Dingkun Long, Pengjun Xie, Meishan Zhang. "Towards General Text
  Embeddings with Multi-stage Contrastive Learning", arXiv:2308.03281 (2023).
- Licence: **MIT**, as declared on the model card (`license: mit`). The repository has no separate licence file
  and names no copyright holder; the MIT terms are reproduced below for the authors of gte.
- Changes made here: format conversion (PyTorch to Core ML), weights quantised to int8, pooling and normalisation
  folded into the model. On the 30-question paraphrase check the converted model's vectors match the original's
  with cosine similarity 0.9999.

Everything runs on the Mac. Nothing is downloaded and nothing is sent anywhere.

## MIT License

Copyright (c) 2023 the authors of gte (General Text Embeddings)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
