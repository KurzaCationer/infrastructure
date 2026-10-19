# Packer trust anchors

These public keys are vendored so image builds do not silently trust a key
fetched during the build. They were refreshed and verified on 2026-08-08.

| File | Authoritative source | Primary fingerprint | File SHA-256 | Expiry |
| --- | --- | --- | --- | --- |
| `opensuse-project-signing-key.asc` | `https://download.opensuse.org/distribution/leap/16.0/repo/oss/repodata/repomd.xml.key` | `AD485664E901B867051AB15F35A2F86E29B700A4` | `b5745739ebfb95b25b8e810f9bcb847fe750ccda598bd85f02f0e974599a6d7e` | 2030-05-27 |
| `rancher-ci-signing-key.asc` | `https://rpm.rancher.io/public.key` | `C8CFF216455126E9B9C918BE925EA29AE257814A` | `7d2415f7fc532c365c8874bfad966566daaa0d04a9a5ba14d1db6080a9c12629` | No expiry |

## Rotation

1. Confirm the rotation through the publisher's official announcement or
   release channel. Do not trust an unexpected key change at the download URL.
2. Download the key from the authoritative HTTPS endpoint and inspect it with
   `gpg --show-keys --with-colons`.
3. Review the complete primary fingerprint, lifecycle, signing capability, and
   file SHA-256. Update the Packer fingerprint pin and this table together.
4. Run `scripts/tests/test_packer_trust_anchors.sh` and
   `scripts/tests/test_leapmicro_verifier.sh`, then complete a real snapshot
   build and boot test before release.
