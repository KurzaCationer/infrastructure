# Packer signing keys

| File | Publisher URL | Primary fingerprint |
| --- | --- | --- |
| `opensuse-project-signing-key.asc` | https://download.opensuse.org/distribution/leap/16.0/repo/oss/repodata/repomd.xml.key | `AD485664E901B867051AB15F35A2F86E29B700A4` |
| `rancher-ci-signing-key.asc` | https://rpm.rancher.io/public.key | `C8CFF216455126E9B9C918BE925EA29AE257814A` |

Confirm rotations through the publisher's release channel before accepting a
changed key. Inspect downloaded keys with `gpg --show-keys --with-colons`.

Update the fingerprint pins in both Packer templates, this table and the changed
file hashes in `../security-bundle.sha256` together.

Verify the bundle, build a snapshot and complete a boot test before deployment.
Run upstream `test_packer_trust_anchors.sh` and `test_leapmicro_verifier.sh` from
the matching Kube-Hetzner checkout when reviewing a bundle update.
