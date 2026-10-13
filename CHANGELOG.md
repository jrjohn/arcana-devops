# Changelog

## 1.0.0 (2026-10-13)


### Features

* add MySQL service to devops stack for CI/CD integration tests ([a1b03c5](https://github.com/jrjohn/arcana-devops/commit/a1b03c594592bfa25824cc0f45f975102d81e5dd))
* **ci:** auto-push Architecture Qube metrics to Prometheus Pushgateway ([9eb4107](https://github.com/jrjohn/arcana-devops/commit/9eb410700550d84f4cbe9cadc15843ae45037e7e))
* **ci:** B2 trigger v5 — 6h per-job cooldown kills the remediation perpetual-motion loop ([6e83c47](https://github.com/jrjohn/arcana-devops/commit/6e83c47e11c6319d43ac5615d5ba8cde3c33646f))
* **host:** monthly Jenkins auto-upgrade with verification and rollback ([#29](https://github.com/jrjohn/arcana-devops/issues/29)) ([8a1414e](https://github.com/jrjohn/arcana-devops/commit/8a1414e444aaeb47449c8a7426e252798e4cc2d2))
* **ops:** devops-deploy-pipeline — GitOps-lite auto-deploy for infra tag bumps ([eccfc60](https://github.com/jrjohn/arcana-devops/commit/eccfc60f5e5902fc3f22b0b75f4743581f66fa18))
* **ops:** plugin-update-bot — Renovate-style weekly PR for Jenkins plugins ([67c8f83](https://github.com/jrjohn/arcana-devops/commit/67c8f833940093737281c40e85b2ad375e49f487))


### Bug Fixes

* archiveArtifacts path + add mapping.txt for R8 deobfuscation ([54add35](https://github.com/jrjohn/arcana-devops/commit/54add35b48e0f4b128916781a480e786c6d602f7))
* change cleanup log path to /data/devops/logs/ (writable by rocky) ([cd1a95e](https://github.com/jrjohn/arcana-devops/commit/cd1a95e1e403d444fc3856ac5abeeaa8cb39f813))
* **ci-disk-gc:** age-based CI network reaper — idle /16 nets exhaust Docker default pool ([#13](https://github.com/jrjohn/arcana-devops/issues/13)) ([93fa918](https://github.com/jrjohn/arcana-devops/commit/93fa918926e477d88d8a7c0529a83051e055e86b))
* **ci-disk-gc:** network reaper never matched docker's Created format ([#24](https://github.com/jrjohn/arcana-devops/issues/24)) ([8cc28aa](https://github.com/jrjohn/arcana-devops/commit/8cc28aa5c6b8d572eded80c9be48d26f5e39ae08))
* **ci:** arch-qube-metrics never pushed real numbers — and pushed wrong ones ([#32](https://github.com/jrjohn/arcana-devops/issues/32)) ([703a0d5](https://github.com/jrjohn/arcana-devops/commit/703a0d5c3304bbdf5718cb8990df902e5db3dd35))
* **ci:** fix node and react pipeline failures ([20ea354](https://github.com/jrjohn/arcana-devops/commit/20ea3548e95c5b14339401fc6f5d458305adb206))
* **compose:** postgres 18 volume must mount /var/lib/postgresql (PGDATA moved) ([29b1dff](https://github.com/jrjohn/arcana-devops/commit/29b1dff06c48857d45316e895c1fe5e0b55da6a4))
* **deploy:** findAll().size() — CPS silently breaks count{closure} (run [#3](https://github.com/jrjohn/arcana-devops/issues/3) no-op'd) ([7300562](https://github.com/jrjohn/arcana-devops/commit/7300562fbd31806eae228d74f485a3f14d62e813))
* **deploy:** HOST_WS 指向 jenkins_home 的現址,deploy pipeline 自 06-08 起找不到 plan.py ([#41](https://github.com/jrjohn/arcana-devops/issues/41)) ([19d3011](https://github.com/jrjohn/arcana-devops/commit/19d301151a3ac3567815f7f5df2871185d0fb00d))
* **deploy:** translate workspace to its host-side path for docker -v ([f92f5b1](https://github.com/jrjohn/arcana-devops/commit/f92f5b14b943057b6b0ae717920a514de9173cad))
* **deploy:** TSV plan protocol — readJSON needs pipeline-utility-steps (not installed) ([356841b](https://github.com/jrjohn/arcana-devops/commit/356841bad9db51ffb64c727f225eaf9038f75f9a))
* **deploy:** zero-closure plan parsing — CPS also breaks findAll/collect over split() arrays ([165256d](https://github.com/jrjohn/arcana-devops/commit/165256df4a63befa5180e7e0328013c2f27beedb))
* **deps:** update golang docker tag to v1.27 ([#33](https://github.com/jrjohn/arcana-devops/issues/33)) ([165ef6a](https://github.com/jrjohn/arcana-devops/commit/165ef6a974d5f172fd3b13741cc67a7d85eff0f1))
* **deps:** update sonarqube docker tag to v26.10.0.133078 ([#40](https://github.com/jrjohn/arcana-devops/issues/40)) ([4767983](https://github.com/jrjohn/arcana-devops/commit/47679839d804164a27f5e63c10c8fe7e1131fc8a))
* **deps:** update sonarqube docker tag to v26.9.0.129388 ([#11](https://github.com/jrjohn/arcana-devops/issues/11)) ([5a763eb](https://github.com/jrjohn/arcana-devops/commit/5a763ebdd4d247f028c436cc82653c675a2e46fc))
* **deps:** update sonatype/nexus3 docker tag to v3.96.4 ([#10](https://github.com/jrjohn/arcana-devops/issues/10)) ([d71bf38](https://github.com/jrjohn/arcana-devops/commit/d71bf38c4c9d7c37d0eb7b83aa34c09d6eda4571))
* **host:** builds_running always returned 0, so emergency prune wiped live builds ([#18](https://github.com/jrjohn/arcana-devops/issues/18)) ([909b300](https://github.com/jrjohn/arcana-devops/commit/909b300ee44731e1dde2a5d8bd97148d1c0af187))
* **host:** reap dangling anonymous docker volumes in ci-disk-gc ([#19](https://github.com/jrjohn/arcana-devops/issues/19)) ([ee1bbc0](https://github.com/jrjohn/arcana-devops/commit/ee1bbc0b6885ddd76ff7c6bce1d23f55b7477496))
* **host:** retry the monthly Jenkins pull and the weekly macmini check ([#37](https://github.com/jrjohn/arcana-devops/issues/37)) ([7c46cb7](https://github.com/jrjohn/arcana-devops/commit/7c46cb7d32607999f103f58dd136c3143f4aa99c))
* **ios:** add match-password credential and locale for TestFlight deploy ([600a8a0](https://github.com/jrjohn/arcana-devops/commit/600a8a05ba5a3b9b5007a9ca51eeb79095d7532c))
* MySQL uses host bind mounts matching production config ([71938f2](https://github.com/jrjohn/arcana-devops/commit/71938f210ccbd54a7d0123ba305257d5b65d9736))
* properly resolve Jenkins admin monitors ([0176960](https://github.com/jrjohn/arcana-devops/commit/01769609a601f2f42c44ae7eafa5c96449bc509d))
* resolve Jenkins admin warnings ([3fbb859](https://github.com/jrjohn/arcana-devops/commit/3fbb859d4ba44cef2e4876092d7c2b09bcafc595))
* sync SonarQube config with actual server settings ([606ddc9](https://github.com/jrjohn/arcana-devops/commit/606ddc9598116238d7488e2f3ac796cb6cb2a4a9))
* update Jenkins pipeline SonarQube configs for all projects ([a5d62eb](https://github.com/jrjohn/arcana-devops/commit/a5d62ebcdd8afd6cf614d579498ffc36b1376935))
