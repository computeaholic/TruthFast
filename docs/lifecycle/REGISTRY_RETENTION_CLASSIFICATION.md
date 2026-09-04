# REGISTRY_RETENTION_CLASSIFICATION

## Non-Runtime Manifest Classification

| image | class | class_name | role | rationale |
|---|---|---|---|---|
| registry.threadforge.local:30500/cert-manager/startupapicheck@sha256:d313d9b8a846c163e52eebe68fd5e7da2457fddda2f144848de17b6fcd6e14f4 | C | upgrade/rollback support | cert management | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/coredns/coredns@sha256:ba9e70dbdf0ff8a77ea63451bb1241d08819471730fe7a35a218a8db2ef7890c | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/csi-node-reg-shim@sha256:b9e218b3bf6d8027c7218cc2c54d155e9d3920321b02bbfd36acbac18b1c65d3 | C | upgrade/rollback support | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/csi-node-shim@sha256:d5899cfe92b8b4fbb097164c269ab6a6bb881e8f63b3531740a667b4312ca1f0 | C | upgrade/rollback support | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/etcd@sha256:303a7560d4c061dcb567258c1c628bee3d50e7770d5f72eb67b2d60ec4bbfcb2 | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/forgesec@sha256:8b03717b53f08cee8422f463a8abd0f8e3f1758dba8f1f8af63eb2616f7937fa | B | diagnostic/recovery tooling | threadforge control | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/frrouting/frr@sha256:6959404cfe5878c641d5619b7348f5b0efb7968ac6e00f1aa42cbf269aa2ddc6 | F | migration compatibility | network/gitops compatibility | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/grafana@sha256:3d0a9cf19db093e616b8731b4ae7ed476c8f69ab5e47cac71b12dfae8536a7c2 | H | orphaned/stale candidate | observability | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kindest-node@sha256:4058ff95ed545fb8cd65c60a16e13650698817d94701322e1aed41f29c11314a | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kindest/kindnetd@sha256:4d4e6f6741f2b33bf6833c570de65b07652c0f8b2a0ee04dfd968f012467ebd6 | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kindest/local-path-provisioner@sha256:ab1ef4bb5fcf72bdf5b9fba8f0979f10894b65a7353680ee3e12172cca1e8052 | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kube-apiserver@sha256:74ea4e3a814490ffe1a66434837aea1e73006d559b65a6321f3e41fc105845b7 | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kube-controller-manager@sha256:8ddc81caccc97ada7e3c53ebe2c03240f25cd123c479752a1c314c402b972028 | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kube-proxy@sha256:7df12f2b1bad9a90a39a1ca558501a4ba66b8943df1d5f2438788aa15c9d23ef | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/kube-scheduler@sha256:96a3e2d1761583447d4ae302128b4956b855d14cdd5bf9ed4637d8b9f0c74a27 | E | bootstrap dependency | cluster infrastructure | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/metallb/controller@sha256:faa8f0d53b3811705910f823f895f797a68729a0fe1f38e36e4a25efeab303bd | F | migration compatibility | network/gitops compatibility | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/metallb/speaker@sha256:b73cc85aaf693bb283cec2b9b14acf788fcf78acd23ae999013b512d37d8a946 | F | migration compatibility | network/gitops compatibility | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/docker.io/envoyproxy/envoy@sha256:3a1dcd02398649de19b46458977f9289645890c0f2283a7d185ae0ed1dcacb7e | D | observability support | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/docker.io/library/python@sha256:c80b8a915802074a84d8e08c1a5af1d94e29e5b87a6177f35c9cd1bcba978c92 | B | diagnostic/recovery tooling | diagnostic utility | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/docker.io/prom/blackbox-exporter@sha256:8d502b55bead7dcac8805fc90cbc93b36e6967360af88cd3213e14ff350ec29d | D | observability support | observability | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/docker.io/prom/pushgateway@sha256:21a7911913498a2732d984a84876d6d729ac2cf6c26802665ea5904c2fc6df62 | D | observability support | observability | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/ghcr.io/dexidp/dex@sha256:97f7ced3a0d3d65108d46f7d64cb487f7433d8166402ab5ff0fffb618625ecde | F | migration compatibility | network/gitops compatibility | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/ghcr.io/spiffe/spire-server@sha256:4dc4d1a224bc2e8ce641a44086cb84bb5aea63cdcf297f77688fa71c0b36ec89 | C | upgrade/rollback support | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/quay.io/argoproj/argocd@sha256:10fc34124a09fd854b5635921e8ad484743dad08d93652a271b2cc2609d4c506 | F | migration compatibility | network/gitops compatibility | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727 | B | diagnostic/recovery tooling | stateful data dependency | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/mirror/registry.k8s.io/metrics-server/metrics-server@sha256:b2d2efaf5ac3b366ed0f839d2412a2c4279d4fc2a2a733f12c52133faed36c41 | D | observability support | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/runtime-ledger-archival@sha256:d3910eec44b77018f06d6a17315188cd085ed1026ddeb424bde1bf557e237390 | B | diagnostic/recovery tooling | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/runtime-ledger-rotation@sha256:d3910eec44b77018f06d6a17315188cd085ed1026ddeb424bde1bf557e237390 | B | diagnostic/recovery tooling | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/runtime-snapshot@sha256:d3910eec44b77018f06d6a17315188cd085ed1026ddeb424bde1bf557e237390 | H | orphaned/stale candidate | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/sig-storage/csi-node-driver-registrar@sha256:11b414474d388fd6e650d08f104f1a4ff43201bada765b8af25d9b489b240edf | H | orphaned/stale candidate | unknown | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/spiffe/spire-agent@sha256:bc2a7e6819435fabcd705c48c01562f46b336231fe0354836c423bbadfa1cac8 | C | upgrade/rollback support | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/spiffe/spire-server@sha256:bff24b204c066f3abc977b4a119eaae3e50af40973e33dd37d60a41996e66eb3 | C | upgrade/rollback support | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/spire-csi-driver@sha256:1009bdf05b43b7c20ff0ca84fbc589c1c936314c80cb0314de01b1fa63720b35 | H | orphaned/stale candidate | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/spire-csr@sha256:570a4e19fc5ca762b94604dc9b4471c06b9bc1d1cbc22128857d33e776dad61f | C | upgrade/rollback support | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/spire-csr@sha256:6f9d5c9c3e65512a5cece30aac84598f7da0980a45ccc8b13385f235939aec42 | C | upgrade/rollback support | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/spire-csr@sha256:6fd60b2743b574f4fdff3e105f8692d8a54e82bd0ac4842478a4b005c24770ea | C | upgrade/rollback support | SPIRE identity plane | derived from runtime absence + reference trace + repo function |
| registry.threadforge.local:30500/threadforge-operator@sha256:fc33152f8732d3081bfe79b2a1689f18e644cacf9cd2b46fd9f0054c341622b7 | B | diagnostic/recovery tooling | threadforge control | derived from runtime absence + reference trace + repo function |

## Counts
- A (active runtime dependency): 0
- B (diagnostic/recovery tooling): 6
- C (upgrade/rollback support): 9
- D (observability support): 4
- E (bootstrap dependency): 9
- F (migration compatibility): 5
- G (deprecated but retained intentionally): 0
- H (orphaned/stale candidate): 4
- I (unknown ownership): 0
