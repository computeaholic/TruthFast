# Third-Party Notices

TruthFast project-owned material is licensed under PolyForm Shield 1.0.0. This
file records third-party material redistributed in the seven tracked compiled
binaries. Dependencies fetched during normal use are not redistributed merely
because repository configuration references them.

## Binary Provenance

| Path | Type and SHA-256 | Origin / producer | Redistribution and notice | Confidence |
| --- | --- | --- | --- | --- |
| `internal/control/identity/identity-controller/bin/controller-gen` | Mach-O arm64; `5328ad87bdb386d98f2f3e3fe40b080ab0fbde455c03a618b495bbb9d19aa6c8` | Kubernetes Authors; upstream `sigs.k8s.io/controller-tools/cmd/controller-gen@v0.20.0` | Allowed under Apache-2.0 with embedded Apache/BSD/MIT attributions retained below | High |
| `platform/build/csi-rebuild/csi-node-shim` | ELF arm64; `08d9e37a18c45c6de9fefcca6aaa2dd4d2d9a42cd4e460e8f350674d2d067653` | ThreadForge build from `platform/cmd/csi-node-shim`; Go module `github.com/threadforge/csi-node-shim` | Redistributed under the project-compatible Apache-2.0 terms where applicable; embedded Apache/BSD attributions retained below | High |
| `platform/build/csi-reg/csi-node-reg-proxy` | ELF arm64; `b6b2623dd815af6ed2fc0be1405e249a8e375389c412750da349f96a59059a05` | ThreadForge build from `platform/cmd/csi-reg-shim`; Go module `github.com/threadforge/csi-reg-shim` | Redistributed under the project-compatible Apache-2.0 terms where applicable; embedded Apache/BSD attributions retained below | High |
| `platform/cmd/csi-node-shim/csi-node-shim` | ELF arm64; `b3912e5f873fd7a5285cc6291457a487dc8b6ba12142bbc243830bcbdb13bf1c` | ThreadForge build from adjacent source; Go module `github.com/threadforge/csi-node-shim` | Redistributed under the project-compatible Apache-2.0 terms where applicable; embedded Apache/BSD attributions retained below | High |
| `platform/cmd/csi-reg-shim/csi-node-reg-proxy` | ELF arm64; `b6b2623dd815af6ed2fc0be1405e249a8e375389c412750da349f96a59059a05` | byte-identical ThreadForge copy of the build above | Redistributed under the project-compatible Apache-2.0 terms where applicable; embedded Apache/BSD attributions retained below | High |
| `platform/cmd/csi-reg-shim/csi-reg-shim` | ELF arm64; `2a70c7f098b3074ca058fe0362cb7c67426e017fab20df38392ce7140ef98178` | ThreadForge build from adjacent source; Go module `github.com/threadforge/csi-reg-shim` | Redistributed under the project-compatible Apache-2.0 terms where applicable; embedded Apache/BSD attributions retained below | High |
| `platform/cmd/threadforge-notifier/threadforge-notifier` | ELF arm64; `74821d23287f8c6122bbb09af8e1459491a90685881e7ed3b16bd8ae6daffbe3` | ThreadForge build from `platform/cmd/threadforge-notifier/main.go` | Project-owned material is governed by the project license; no embedded third-party module reported by Go metadata | High |

The inventory was reconstructed from each binary's Go build metadata. The
tracked binaries total 110,997,616 bytes. The repository retains them for
current build/deployment consumers; this notice does not claim they are all
native V1 runtime entrypoints.

No binary in this inventory has an Apache-2.0 conflict or unknown provenance.
Dependency license text was recovered from exact versions embedded in Go build
metadata, not inferred from executable names.

## Apache-2.0 Components

The full Apache License 2.0 text is in
[`THIRD_PARTY_LICENSES/Apache-2.0.txt`](THIRD_PARTY_LICENSES/Apache-2.0.txt). Redistributed
Apache-2.0 modules include:

- `github.com/container-storage-interface/spec` v1.6.0 and v1.7.0
- `github.com/go-logr/logr` v1.4.3
- `github.com/go-openapi/jsonpointer` v0.21.0
- `github.com/go-openapi/jsonreference` v0.20.2
- `github.com/go-openapi/swag` v0.23.0
- `github.com/google/gnostic-models` v0.7.0
- `github.com/modern-go/concurrent` and `github.com/modern-go/reflect2`
- `github.com/spf13/cobra` v1.10.2
- `go.yaml.in/yaml/v2` v2.4.3 and `go.yaml.in/yaml/v3` v3.0.4
- `google.golang.org/genproto/googleapis/rpc` versions embedded by the binaries
- `google.golang.org/grpc` v1.57.0, v1.58.0, and v1.72.2
- `gopkg.in/yaml.v2` v2.4.0 and `gopkg.in/yaml.v3` v3.0.1
- Kubernetes modules embedded by `controller-gen` and `csi-reg-shim`, including
  `k8s.io/api`, `apiextensions-apiserver`, `apimachinery`, `code-generator`,
  `gengo/v2`, `klog/v2`, `kube-openapi`, `kubelet`, and `utils`
- `sigs.k8s.io/controller-tools` v0.20.0, `json`, `randfill`,
  `structured-merge-diff/v6`, and `yaml`

Required upstream notice text follows.

### gRPC

Copyright 2014 gRPC authors.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at <http://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

### YAML

Copyright 2011-2016 Canonical Ltd.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the
License at <http://www.apache.org/licenses/LICENSE-2.0>.

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

### randfill

When donating the randfill project to the CNCF, its maintainers could not reach
all gofuzz contributors to sign the CNCF CLA. The upstream NOTICE identifies
the following submissions under section 7 of that CLA:

Submitted on behalf of third parties: Daniel Nephin, Alexey Palazhchenko, Bruno
Bigras, Samir, Eyal Posener, Ashik Paul, Kwongtai, Eric Cornelissen, Robert-Andre
Mauchin, Andrew Pan, Zhiqiang Zhou, and Disconnect3d.

## BSD-3-Clause Components

Redistributed BSD-3-Clause components include `github.com/golang/protobuf`,
`github.com/spf13/pflag`, `golang.org/x/mod`, `x/net`, `x/sync`, `x/sys`,
`x/text`, `x/tools`, `google.golang.org/protobuf`, and `gopkg.in/inf.v0` at the
versions recorded in the binaries' Go build metadata.

Copyright holders include The Go Authors; Alex Ogier; and Peter Suranyi.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## MIT Components

Redistributed MIT components and their copyright notices are:

- `github.com/fatih/color` v1.18.0: Copyright (c) 2013 Fatih Arslan
- `github.com/fxamacker/cbor/v2` v2.9.0: Copyright (c) 2019-present Faye Amacker
- `github.com/gobuffalo/flect` v1.0.3: Copyright (c) 2019 Mark Bates
- `github.com/josharian/intern` v1.0.0: Copyright (c) 2019 Josh Bleecher Snyder
- `github.com/json-iterator/go` v1.1.12: Copyright (c) 2016 json-iterator
- `github.com/mailru/easyjson` v0.7.7: Copyright (c) 2016 Mail.Ru Group
- `github.com/mattn/go-colorable` v0.1.13: Copyright (c) 2016 Yasuhiro Matsumoto
- `github.com/mattn/go-isatty` v0.0.20: Copyright (c) Yasuhiro Matsumoto
- `github.com/x448/float16` v0.8.4: Copyright (c) 2019 Montgomery Edwards and Faye Amacker

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Scope

Third-party names and trademarks remain the property of their respective
owners. This attribution file does not change any upstream license and does not
grant trademark rights.
