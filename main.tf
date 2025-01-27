resource "random_pet" "sftp" {
  length    = 2
  separator = "-"
}

locals {
  name = var.name == null ? random_pet.sftp.id : var.name
}

resource "aws_iam_role" "logging" {
  count = var.logging_role == null ? 1 : 0
  name  = "${local.name}-transfer-logging"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "transfer.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "logging" {
  count = var.logging_role == null ? 1 : 0
  name  = "${local.name}-transfer-logging"
  role  = join(",", aws_iam_role.logging.*.id)

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:CreateLogGroup",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/transfer/*"
    }
  ]
}
POLICY
}

resource "aws_transfer_server" "public" {
  # checkov:skip=CKV_AWS_164: Exposing server publicly depends on user
  count                  = var.sftp_type == "PUBLIC" ? 1 : 0
  endpoint_type          = var.sftp_type
  protocols              = var.protocols
  certificate            = var.certificate_arn
  identity_provider_type = var.identity_provider_type
  url                    = var.api_gw_url
  invocation_role        = var.invocation_role
  directory_id           = var.directory_id
  function               = var.function_arn
  logging_role           = var.logging_role == null ? join(",", aws_iam_role.logging.*.arn) : var.logging_role
  force_destroy          = var.force_destroy
  security_policy_name   = var.security_policy_name
  host_key               = var.host_key

  tags = merge({
    Name = local.name
  }, var.tags)
}

resource "aws_security_group" "sftp_vpc" {
  # checkov:skip=CKV2_AWS_5: Associated to SFTP server
  # checkov:skip=CKV_AWS_24: Port 22 open required to the world
  count       = var.sftp_type == "VPC" && lookup(var.endpoint_details, "security_group_ids", null) == null ? 1 : 0
  name        = "${local.name}-sftp-vpc"
  description = "Security group for SFTP VPC"
  vpc_id      = lookup(var.endpoint_details, "vpc_id")

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow connections from everywhere on port 22"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound connections"
  }
}

locals {
  create_eip = var.sftp_type == "VPC" && lookup(var.endpoint_details, "address_allocation_ids", null) == null && length(lookup(var.endpoint_details, "subnet_ids", [])) > 0
}

resource "aws_eip" "sftp_vpc" {
  count = local.create_eip ? length(lookup(var.endpoint_details, "subnet_ids", [])) : 0
  vpc   = true
  tags  = var.tags
}

resource "aws_transfer_server" "vpc" {
  # checkov:skip=CKV_AWS_164: Exposing server publicly depends on user
  count         = var.sftp_type != "PUBLIC" ? 1 : 0
  endpoint_type = var.sftp_type
  protocols     = var.protocols
  certificate   = var.certificate_arn

  endpoint_details {
    vpc_id                 = lookup(var.endpoint_details, "vpc_id", null)
    vpc_endpoint_id        = lookup(var.endpoint_details, "vpc_endpoint_id", null)
    subnet_ids             = lookup(var.endpoint_details, "subnet_ids", null)
    security_group_ids     = lookup(var.endpoint_details, "security_group_ids", aws_security_group.sftp_vpc.*.id)
    address_allocation_ids = local.create_eip ? aws_eip.sftp_vpc.*.id : lookup(var.endpoint_details, "address_allocation_ids", null)

  }

  identity_provider_type = var.identity_provider_type
  url                    = var.api_gw_url
  invocation_role        = var.invocation_role
  directory_id           = var.directory_id
  function               = var.function_arn

  logging_role         = var.logging_role == null ? join(",", aws_iam_role.logging.*.arn) : var.logging_role
  force_destroy        = var.force_destroy
  security_policy_name = var.security_policy_name
  host_key             = var.host_key

  tags = merge({
    Name = local.name
  }, var.tags)
}

locals {
  server_id = var.sftp_type == "PUBLIC" ? join(",", aws_transfer_server.public.*.id) : join(",", aws_transfer_server.vpc.*.id)
  server_ep = var.sftp_type == "PUBLIC" ? join(",", aws_transfer_server.public.*.endpoint) : join(",", aws_transfer_server.vpc.*.endpoint)
}

data "aws_route53_zone" "primary" {
  count = var.hosted_zone == null ? 0 : 1
  name  = var.hosted_zone
}

resource "aws_route53_record" "sftp" {
  count   = var.hosted_zone == null ? 0 : 1
  zone_id = join(",", data.aws_route53_zone.primary.*.zone_id)
  name    = "${var.sftp_sub_domain}.${var.hosted_zone}"
  type    = "CNAME"
  ttl     = "60"
  records = [local.server_ep]
}

resource "aws_iam_role" "user" {
  for_each           = var.sftp_users
  name               = "${local.name}-sftp-user-${each.key}"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "transfer.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "user" {
  for_each = var.sftp_users
  name     = "${local.name}-sftp-user-${each.key}"
  role     = aws_iam_role.user[each.key].id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowListingOfUserFolder",
      "Action": [
        "s3:ListBucket"
      ],
      "Effect": "Allow",
      "Resource": [
        "arn:aws:s3:::${split("/", trim(each.value, "/"))[0]}"
      ],
      "Condition": {
          "StringLike": {
              "s3:prefix": [
                  "${trimsuffix(replace(each.value, "/^[^/]+\\//", ""), "/")}/*",
                  "${trimsuffix(replace(each.value, "/^[^/]+\\//", ""), "/")}"
              ]
          }
      }

    },
    {
      "Sid": "HomeDirObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObjectVersion",
        "s3:DeleteObject",
        "s3:GetObjectVersion",
        "s3:GetObjectACL",
        "s3:PutObjectACL"
      ],
      "Resource": "arn:aws:s3:::${trimsuffix(each.value, "/")}/*"
    }
  ]
}
POLICY
}

resource "null_resource" "restricted_home" {
  triggers = {
    key = var.restricted_home
  }
}

resource "aws_transfer_user" "this" {
  for_each  = var.sftp_users
  server_id = local.server_id
  user_name = each.key

  home_directory_type = var.restricted_home ? "LOGICAL" : null
  home_directory      = var.restricted_home ? null : "/${each.value}"

  dynamic "home_directory_mappings" {
    for_each = var.restricted_home ? [
      {
        entry = "/"
        target = "/${each.value}"
      }
    ] : []

    content {
      entry  = home_directory_mappings.value.entry
      target = home_directory_mappings.value.target
    }
  }

  role = aws_iam_role.user[each.key].arn
  tags = merge({ User = each.key }, var.tags)

  lifecycle {
    replace_triggered_by = [
      null_resource.restricted_home
    ]
  }
}

resource "aws_transfer_ssh_key" "this" {
  for_each   = var.sftp_users_ssh_key
  server_id  = local.server_id
  user_name  = each.key
  body       = each.value
  depends_on = [aws_transfer_user.this]

  lifecycle {
    replace_triggered_by = [
      aws_transfer_user.this
    ]
  }
}
