# Teammates granted SSM Session Manager shell access to the ui/api instances
# (see access.tf). Add a name and open a PR to grant access; remove one and
# apply to revoke it. This file is git-tracked on purpose — access.tf's
# .gitignore has *.tfvars, with an explicit exception for this file.
ssm_user_names = ["chaitraaws", "shadabadmin"]
