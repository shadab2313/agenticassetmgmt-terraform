# Two-tier application environment on AWS

Terraform for a UI server and backend API behind a single Application Load Balancer, deployed into an existing VPC alongside an existing database.

## What gets created

| Layer | Resources |
|---|---|
| Network | Nothing. Deploys into your existing VPC and subnets. |
| Ingress | ALB, two target groups, HTTP and HTTPS listeners, `/api/*` path rule |
| Compute | Plain EC2 instances for both tiers, registered directly to target groups, IAM role with SSM |
| Data | Nothing. Connects to your existing database. |
| Security | Three new security groups, plus one ingress rule added to your database's existing group |

## Ports

| Group | Port | Source |
|---|---|---|
| `alb` | 443 | `0.0.0.0/0` |
| `alb` | 80 | `0.0.0.0/0` (redirects to 443 when a cert is set) |
| `ui` | 3000 | `alb` |
| `api` | 8080 | `alb` and `ui` |
| your existing db group | 5432 | `api` (rule added to your group) |

Port 22 is deliberately absent. Shell access goes through SSM Session Manager.

## Prerequisites from your existing VPC

Three IDs go in `terraform.tfvars`. Find them with:

```bash
aws rds describe-db-instances \
  --query 'DBInstances[*].{db:DBInstanceIdentifier,vpc:DBSubnetGroup.VpcId,sg:VpcSecurityGroups[0].VpcSecurityGroupId,endpoint:Endpoint.Address}' \
  --output table

aws ec2 describe-subnets --filters Name=vpc-id,Values=vpc-XXXX \
  --query 'Subnets[*].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock,public:MapPublicIpOnLaunch}' \
  --output table
```

| Variable | Requirement |
|---|---|
| `vpc_id` | The VPC your database is in |
| `alb_subnet_ids` | Two or more **public** subnets in **different AZs** |
| `app_subnet_ids` | One **private** subnet, for single-AZ compute |
| `existing_db_security_group_id` | The group already attached to your database |

Wrong subnet types are the most common setup mistake, and they fail in different ways:

**ALB subnets must be public** — a route to an internet gateway. In the `describe-subnets` output above, `public: True` means `MapPublicIpOnLaunch` is set, which is a good signal but not proof. Confirm the route table has a `0.0.0.0/0` route to an `igw-`. A private subnet here produces an ALB that provisions fine and never receives traffic.

**App subnets need outbound internet** — via NAT gateway, or VPC endpoints for `ssm`, `ssmmessages` and `ec2messages`. Without one of those, instances launch and run, but the SSM agent never registers and you have no way to get a shell. Since there is no port 22 rule anywhere in this config, that leaves you locked out.

Plan-time preconditions catch the two-AZ requirement and subnets belonging to the wrong VPC. They cannot catch public-vs-private, so check that yourself.

**Credentials.** If your database password is in Secrets Manager, set `existing_db_secret_arn` and the API instance role gets read access automatically. The instance receives the ARN in `/etc/app.env` and fetches the password at runtime. Passing the password through user data would put it in plaintext where anything on the instance can read it via IMDS.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# edit ports, region, capacity

terraform init
terraform plan
terraform apply
```

First apply takes roughly 2 minutes. There is no VPC or NAT gateway to wait on.

Then:

```bash
curl "$(terraform output -raw app_url)"
curl "$(terraform output -raw app_url)/api/health"
```

Both should answer from the placeholder servers in the user data. Once that works, replace the `user_data` blocks in `compute.tf` with your real bootstrap and run `terraform apply` again — the instance refresh will roll instances one at a time.

## Adding HTTPS

The ALB's region is fixed by `region` in `terraform.tfvars` — an ACM cert must be requested in that same region. (This only matters for an ALB; CloudFront is the one that specifically requires `us-east-1`.)

**If your DNS is in Route 53**, request and validate the cert there, then set `certificate_arn`.

**If your DNS is elsewhere (e.g. Cloudflare)**, set `domain_name` instead and this stack requests the cert for you:

```bash
terraform apply   # creates the ACM certificate, still PENDING_VALIDATION
terraform output acm_validation_record
```

Add the CNAME from that output in Cloudflare — **DNS only / grey-clouded**, not proxied, or validation will never see it. ACM issues the certificate on its own once the record resolves (usually a few minutes) — check with `terraform output acm_certificate_status`.

AWS refuses to attach a certificate to the ALB until it's `ISSUED`, so `domain_name` alone does not turn on HTTPS by itself. Once the status shows `ISSUED`, copy the ARN from `terraform output acm_certificate_arn` into `certificate_arn` in `terraform.tfvars` and apply again — that second apply is what actually creates the HTTPS listener and switches port 80 to a 301 redirect.

Already have a certificate ARN? Set `certificate_arn` directly and it takes precedence over `domain_name`.

## Replacing the NAT Gateway with a NAT instance

A NAT Gateway's flat hourly charge (~$66/month) dominates a low-traffic dev environment's bill — often more than the entire app tier combined. `nat_instance.tf` can swap it for a self-managed `t3a.nano` doing the same job for ~$3.50/month. Off by default; opt in via `nat_instance_enabled`.

This is the one place the "Terraform touches nothing it doesn't own" rule (see `network.tf`) has a deliberate, narrow exception: one route in your private route table, toggled between the existing NAT Gateway and the new instance — never the route table itself.

Two flags keep the cutover reversible instead of a single risky `apply`:

```bash
# 1. Stand the instance up. Zero traffic impact — the live route still
#    points at the existing NAT Gateway.
#    Set in terraform.tfvars: nat_instance_enabled = true
terraform apply

# 2. Verify it before it carries anything real.
aws ssm start-session --target "$(terraform output -raw nat_instance_id)"
#   sysctl net.ipv4.ip_forward        # expect: = 1
#   sudo iptables -t nat -L -n -v     # expect: a MASQUERADE rule

# 3. Cut over. Updates the one route in place.
#    Set in terraform.tfvars: use_nat_instance_for_egress = true
terraform apply

# 4. Confirm the app and SSM still work. If not, flip
#    use_nat_instance_for_egress back to false and apply — instant
#    rollback, doesn't depend on the instance being reachable.
curl "$(terraform output -raw app_url)"
aws ssm start-session --target "$(terraform output -json instance_ids | jq -r .ui[0])"
```

Once stable, delete the old NAT Gateway and release its EIP by hand (`aws ec2 delete-nat-gateway`, `aws ec2 release-address`) — that's the step that actually stops the old charge. Left running alongside the new instance until you're confident, by design.

## Cost

| Item | Monthly |
|---|---|
| ALB | ~$17 + traffic |
| 2× t3.small | ~$30 |

Around $47/month idle. No NAT gateway line item, because you are reusing the one already in your VPC — that is roughly $33/month saved versus building a separate network.

## Single AZ, and the one exception

Everything that runs lives in one availability zone: pass a single subnet ID in `app_subnet_ids` and all instances land there.

The load balancer is the exception, and it is not negotiable. AWS rejects an ALB whose subnets do not span at least two availability zones, so `alb_subnet_ids` needs two. The second one holds nothing — the ALB simply requires a presence there. If you genuinely want zero multi-AZ footprint, the ALB has to go, and you would expose instances directly or put a single NGINX box in front. That trades away TLS termination, health checks, and path routing, which is usually a bad deal.

## No autoscaling group

Instances are plain `aws_instance` resources attached to the target groups by `aws_lb_target_group_attachment`. Simpler to reason about, with three consequences:

- **A failed instance stays failed.** Nothing replaces it. The ALB will pull it from rotation, and if it was the only one in its tier, that tier is down until you act.
- **Editing `user_data` replaces the instance**, because `user_data_replace_on_change = true`. With one instance per tier that means downtime on apply. Comment that line out if you would rather deploy app changes out of band and never let Terraform touch a running box.
- **Scaling is manual.** Change `ui_instance_count` or `api_instance_count` and apply.

For a dev environment this is usually the right trade. Before production, the autoscaling group is the first thing to add back. The NAT gateway is the surprise for most people. To cut it: put the app tier in public subnets with no public IP (less secure), or add VPC endpoints for the specific services you need and drop NAT entirely (more moving parts, cheaper at scale).

Set `single_nat_gateway = false` for production so a single AZ failure doesn't take out outbound traffic for the whole app tier.

## Troubleshooting

**503 from the ALB, targets show unhealthy.** Almost always the health check path. Check Target Groups in the console — the "Health status details" column gives the actual reason. Common causes: the path returns 404, the app binds to `127.0.0.1` instead of `0.0.0.0`, or the app isn't up yet within the 120s grace period.

**Targets healthy but requests time out.** Check the security group direction — `ui` needs ingress *from* `alb`, and `alb` needs egress *to* `ui`. Both sides are required.

**Instances don't appear in Session Manager.** The SSM agent needs outbound HTTPS. Confirm the NAT gateway exists and the private route table has a default route pointing at it. Instance IDs are in the `instance_ids` output.

**An instance died and did not come back.** Expected — there is no autoscaling group. Run `terraform apply` to rebuild it, or start it from the console if it was only stopped.

**API cannot reach the database.** Confirm the rule landed on your database's group: `aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-xxxx`. If it is there and connections still hang, check the database is not in a subnet with a NACL blocking the app subnet's CIDR — NACLs are stateless and evaluated separately from security groups.

**`/api/*` requests hit the UI instead.** Listener rule priority. Lower numbers evaluate first; the rule here is priority 100 and the default action is last, so this should work unless another rule was added below 100.

## Next steps not covered here

- Route 53 alias record (use the `alb_dns_name` and `alb_zone_id` outputs)
- WAF on the ALB
- Autoscaling groups and scaling policies, when you outgrow single-AZ
- Moving to ECS or EKS if you'd rather not manage instances
