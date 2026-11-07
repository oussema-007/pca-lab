# Blockers (need the human)

## B1 - lb01 has no Red Hat content access
- Symptom: `subscription-manager status` says "Consumer profile 1674ab66-... has been deleted from the server"; `dnf` gets HTTP 403 from cdn.redhat.com.
- Impact: no `dnf update --security` on lb01, no packages from the CDN.
- Workaround applied: local repo from the RHEL 9.6 DVD attached to the VM (HAProxy 2.8 RPM from Red Hat media).
- Human action: re-register lb01 (`subscription-manager clean && subscription-manager register`) with your Red Hat account, then run `sudo dnf -y update --security` on lb01. I did not do it (rule 4).
