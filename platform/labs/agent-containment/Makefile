NS := agents-lab
REGISTRY := registry.threadforge.local:30500/agents-lab

.PHONY: images deploy rollout wait ready spiffe-research spiffe-writer spiffe-attacker logs-attacker demo attack-lateral attack-exfiltration attack-scan test-policy-removal verify-allowed-path verify-policy-causality verify-identities verify

images:
	docker buildx build --builder threadforge-builder --platform linux/arm64 --push -t $(REGISTRY)/research-agent agents/research-agent
	docker buildx build --builder threadforge-builder --platform linux/arm64 --push -t $(REGISTRY)/writer-agent agents/writer-agent
	docker buildx build --builder threadforge-builder --platform linux/arm64 --push -t $(REGISTRY)/attacker-agent agents/attacker-agent

deploy: images
	bash ../../../scripts/install/deploy_lab.sh
	$(MAKE) wait

rollout:
	kubectl -n $(NS) rollout restart deploy/research-agent deploy/writer-agent deploy/attacker-agent
	$(MAKE) wait

wait:
	kubectl -n $(NS) rollout status deploy/research-agent --timeout=180s
	kubectl -n $(NS) rollout status deploy/writer-agent --timeout=180s
	kubectl -n $(NS) rollout status deploy/attacker-agent --timeout=180s

ready:
	kubectl -n $(NS) get pods -o wide

spiffe-research:
	kubectl -n $(NS) exec deploy/research-agent -- printenv | grep SPIFFE

spiffe-writer:
	kubectl -n $(NS) exec deploy/writer-agent -- printenv | grep SPIFFE

spiffe-attacker:
	kubectl -n $(NS) exec deploy/attacker-agent -- printenv | grep SPIFFE

logs-attacker:
	kubectl -n $(NS) logs deploy/attacker-agent --tail=100

demo:
	$(MAKE) deploy
	$(MAKE) attack-lateral
	$(MAKE) logs-attacker

attack-lateral:
	bash scenarios/attack_lateral.sh

attack-exfiltration:
	bash scenarios/attack_exfiltration.sh

attack-scan:
	bash scenarios/attack_scan.sh

test-policy-removal:
	bash ../../../scripts/test_policy_removal.sh

verify-allowed-path:
	bash scenarios/verify_allowed_path.sh

verify-policy-causality:
	bash scenarios/policy_causality.sh

verify-identities:
	bash scenarios/identity_evidence.sh

verify:
	bash scenarios/verify_all.sh
