# Create and attach bigip tmm network interfaces
resource "aws_network_interface" "az1_tenant_mgmt" {
  depends_on      = [aws_security_group.tenant_sg_ext_mgmt]
  subnet_id       = aws_subnet.az1_tenant_mgmt.id
  private_ips     = [var.az1_tenantF5.mgmt]
  security_groups = [aws_security_group.tenant_sg_ext_mgmt.id]
  #source_dest_check = false
}

resource "aws_network_interface" "az1_tenant_external" {
  depends_on      = [aws_security_group.tenant_sg_internal]
  subnet_id       = aws_subnet.az1_tenant_ext.id
  #    bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674
  #    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  private_ips     = [var.az1_tenantF5.tenant_ext_self]
  security_groups = [aws_security_group.tenant_sg_internal.id]
  source_dest_check = false
  tags              = {
    f5_cloud_failover_label = tenant_az_failover
  }
  lifecycle {
    ignore_changes = [
      private_ips,
    ]
  }  
}

resource "null_resource" "az1_tenant_external_secondary_ips" {
  depends_on = [aws_network_interface.az1_tenant_external, aws_instance.az1_tenant_bigip]
  # Use the "aws ec2 assign-private-ip-addresses" command to correctly add secondary addresses to an existing network interface 
  #    -> Workaround for bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  #    -> "depends_on bigip" is required because the assign-private-ip-addresses command fails otherwise

  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      aws ec2 assign-private-ip-addresses --region ${var.aws_region} --network-interface-id ${aws_network_interface.az1_tenant_external.id} --private-ip-addresses ${var.az1_tenantF5.tenant_ext_vip}
    EOF
  }
}

resource "aws_network_interface" "az1_tenant_internal" {
  depends_on      = [aws_security_group.tenant_sg_internal]
  subnet_id       = aws_subnet.az1_tenant_int.id
  #    bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674
  #    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
#  private_ips     = [var.az1_tenantF5.tenant_int_self, var.az1_tenantF5.tenant_int_vip]
  private_ips     = [var.az1_tenantF5.tenant_int_self]
  security_groups = [aws_security_group.tenant_sg_internal.id]
  source_dest_check = false
  tags              = {
    f5_cloud_failover_label = tenant_az_failover
  }
  lifecycle {
    ignore_changes = [
      private_ips,
    ]
  }  
}

resource "null_resource" "az1_tenant_internal_secondary_ips" {
  depends_on = [aws_network_interface.az1_tenant_internal, aws_instance.az1_tenant_bigip]
  # Use the "aws ec2 assign-private-ip-addresses" command to correctly add secondary addresses to an existing network interface 
  #    -> Workaround for bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  #    -> "depends_on bigip" is required because the assign-private-ip-addresses command fails otherwise

  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      aws ec2 assign-private-ip-addresses --region ${var.aws_region} --network-interface-id ${aws_network_interface.az1_tenant_internal.id} --private-ip-addresses ${var.az1_tenantF5.tenant_int_vip}
    EOF
  }
}

# Create elastic IP and map to "VIP" on external tenant nic
resource "aws_eip" "eip_az1_tenant_mgmt" {
  depends_on                = [aws_network_interface.az1_tenant_mgmt]
  vpc                       = true
  network_interface         = aws_network_interface.az1_tenant_mgmt.id
  associate_with_private_ip = var.az1_tenantF5.mgmt
}

resource "aws_eip" "eip_az1_tenant_external" {
  depends_on                = [aws_network_interface.az1_tenant_external, aws_internet_gateway.tenantGw]
  vpc                       = true
  network_interface         = aws_network_interface.az1_tenant_external.id
  associate_with_private_ip = var.az1_tenantF5.tenant_ext_self  
}

#Big-IP 1
resource "aws_instance" "az1_tenant_bigip" {
  depends_on    = [aws_subnet.az1_tenant_mgmt, aws_security_group.tenant_sg_ext_mgmt, aws_network_interface.az1_tenant_mgmt]
  ami           = var.ami_f5image_name
  instance_type = var.ami_tenant_f5instance_type
  availability_zone           = "${var.aws_region}a"
  user_data     = data.template_file.az1_tenantF5_vm_onboard.rendered
  iam_instance_profile        = aws_iam_instance_profile.bigip-failover-extension-iam-instance-profile.name
  key_name      = "kp${var.tag_name}"
  root_block_device {
    delete_on_termination = true
  }
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.az1_tenant_mgmt.id
  }
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.az1_tenant_external.id
  }
  network_interface {
    device_index         = 2
    network_interface_id = aws_network_interface.az1_tenant_internal.id
  }
  provisioner "remote-exec" {
    connection {
      host     = self.public_ip
      type     = "ssh"
      user     = var.uname
      password = var.upassword
    }
    when = create
    inline = [
      "until [ -f ${var.onboard_log} ]; do sleep 120; done; sleep 120"
    ]
  }
  provisioner "remote-exec" {
    connection {
      host     = self.public_ip
      type     = "ssh"
      user     = var.uname
      password = var.upassword

    }
    when = destroy
    inline = [
      "echo y | tmsh revoke sys license"
    ]
    on_failure = continue
  }

  tags = {
    Name = "${var.tag_name}-${var.az1_tenantF5.hostname}"
  }
}


## AZ1 DO Declaration
data "template_file" "az1_tenantCluster_do_json" {
  template = "${file("${path.module}/tenant_clusterAcrossAZs_do.tpl.json")}"
  vars = {
    #Uncomment the following line for BYOL
    regkey         = var.tenant_bigip_lic1
    banner_color   = "red"
    host1          = var.az1_tenantF5.hostname
    host2          = var.az2_tenantF5.hostname
    local_host     = var.az1_tenantF5.hostname
    local_selfip1  = var.az1_tenantF5.tenant_ext_self
    local_selfip2  = var.az1_tenantF5.tenant_int_self
    remote_selfip  = var.az2_tenantF5.mgmt
    mgmt_gw        = local.az1_mgmt_gw
    gateway        = local.az1_tenant_ext_gw
    dns_server     = var.dns_server
    ntp_server     = var.ntp_server
    timezone       = var.timezone
    admin_user     = var.uname
    admin_password = var.upassword

    #app1_net        = "${local.app1_net}"
    #app1_net_gw     = "${local.app1_net_gw}"
  }
}
# Render tenant DO declaration
resource "local_file" "az1_tenantCluster_do_file" {
  content  = data.template_file.az1_tenantCluster_do_json.rendered
  filename = "${path.module}/${var.az1_tenantCluster_do_json}"
}


# Create and attach bigip tmm network interfaces
resource "aws_network_interface" "az2_tenant_mgmt" {
  depends_on      = [aws_security_group.tenant_sg_ext_mgmt]
  subnet_id       = aws_subnet.az2_tenant_mgmt.id
  private_ips     = [var.az2_tenantF5.mgmt]
  security_groups = [aws_security_group.tenant_sg_ext_mgmt.id]
}

resource "aws_network_interface" "az2_tenant_external" {
  depends_on      = [aws_security_group.tenant_sg_internal]
  subnet_id       = aws_subnet.az2_tenant_ext.id
  #    bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674
  #    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  private_ips     = [var.az2_tenantF5.tenant_ext_self]
  security_groups = [aws_security_group.tenant_sg_internal.id]
  source_dest_check = false
  tags              = {
    f5_cloud_failover_label = tenant_az_failover
  }
  lifecycle {
    ignore_changes = [
      private_ips,
    ]
  }  
}

resource "null_resource" "az2_tenant_external_secondary_ips" {
  depends_on = [aws_network_interface.az2_tenant_external, aws_instance.az2_tenant_bigip]
  # Use the "aws ec2 assign-private-ip-addresses" command to correctly add secondary addresses to an existing network interface 
  #    -> Workaround for bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  #    -> "depends_on bigip" is required because the assign-private-ip-addresses command fails otherwise

  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      aws ec2 assign-private-ip-addresses --region ${var.aws_region} --network-interface-id ${aws_network_interface.az2_tenant_external.id} --private-ip-addresses ${var.az2_tenantF5.tenant_ext_vip}
    EOF
  }
}

resource "aws_network_interface" "az2_tenant_internal" {
  depends_on      = [aws_security_group.tenant_sg_internal]
  subnet_id       = aws_subnet.az2_tenant_int.id
  #    bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674
  #    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  private_ips     = [var.az2_tenantF5.tenant_int_self]
  security_groups = [aws_security_group.tenant_sg_internal.id]
  source_dest_check = false
  tags              = {
    f5_cloud_failover_label = tenant_az_failover
  }
  lifecycle {
    ignore_changes = [
      private_ips,
    ]
  }  
}

resource "null_resource" "az2_tenant_internal_secondary_ips" {
  depends_on = [aws_network_interface.az2_tenant_internal, aws_instance.az2_tenant_bigip]
  # Use the "aws ec2 assign-private-ip-addresses" command to correctly add secondary addresses to an existing network interface 
  #    -> Workaround for bug: https://github.com/terraform-providers/terraform-provider-aws/issues/10674    -> can't trust that the first IP will be set as the primary if you private_ips is set to more than one address...
  #    -> assumed that due to this bug, the primary and secondary addresses will be reversed
  #    -> "depends_on bigip" is required because the assign-private-ip-addresses command fails otherwise

  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      aws ec2 assign-private-ip-addresses --region ${var.aws_region} --network-interface-id ${aws_network_interface.az2_tenant_internal.id} --private-ip-addresses ${var.az2_tenantF5.tenant_int_vip}
    EOF
  }
}

resource "aws_eip" "eip_az2_tenant_mgmt" {
  depends_on                = [aws_network_interface.az2_tenant_mgmt]
  vpc                       = true
  network_interface         = aws_network_interface.az2_tenant_mgmt.id
  associate_with_private_ip = var.az2_tenantF5.mgmt
}

resource "aws_eip" "eip_az2_tenant_external" {
  depends_on                = [aws_network_interface.az2_tenant_external, aws_internet_gateway.tenantGw]
  vpc                       = true
  network_interface         = aws_network_interface.az2_tenant_external.id
  associate_with_private_ip = var.az2_tenantF5.tenant_ext_self
}


# BigIP 2
resource "aws_instance" "az2_tenant_bigip" {
  depends_on        = [aws_subnet.az2_tenant_mgmt, aws_security_group.tenant_sg_ext_mgmt, aws_network_interface.az2_tenant_mgmt]
  ami               = var.ami_f5image_name
  instance_type     = var.ami_tenant_f5instance_type
  availability_zone = "${var.aws_region}b"
  user_data         = data.template_file.az2_tenantF5_vm_onboard.rendered
  iam_instance_profile        = aws_iam_instance_profile.bigip-failover-extension-iam-instance-profile.name
  key_name          = "kp${var.tag_name}"
  root_block_device {
    delete_on_termination = true
  }
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.az2_tenant_mgmt.id
  }
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.az2_tenant_external.id
  }
  network_interface {
    device_index         = 2
    network_interface_id = aws_network_interface.az2_tenant_internal.id
  }
  provisioner "remote-exec" {
    connection {
      host     = self.public_ip
      type     = "ssh"
      user     = var.uname
      password = var.upassword
    }
    when = create
    inline = [
      "until [ -f ${var.onboard_log} ]; do sleep 120; done; sleep 120"
    ]
  }

  provisioner "remote-exec" {
    connection {
      host     = self.public_ip
      type     = "ssh"
      user     = var.uname
      password = var.upassword
    }
    when = "destroy"
    inline = [
      "echo y | tmsh revoke sys license"
    ]
    on_failure = "continue"
  }

  tags = {
    Name = "${var.tag_name}-${var.az2_tenantF5.hostname}"
  }
}


## AZ2 DO Declaration
data "template_file" "az2_tenantCluster_do_json" {
  template = "${file("${path.module}/tenant_clusterAcrossAZs_do.tpl.json")}"
  vars = {
    #Uncomment the following line for BYOL
    regkey         = var.tenant_bigip_lic2
    banner_color   = "red"
    host1          = var.az2_tenantF5.hostname
    host2          = var.az1_tenantF5.hostname
    local_host     = var.az2_tenantF5.hostname
    local_selfip1  = var.az2_tenantF5.tenant_ext_self
    local_selfip2  = var.az2_tenantF5.tenant_int_self
    remote_selfip  = var.az1_tenantF5.mgmt
    mgmt_gw        = local.az2_mgmt_gw
    gateway        = local.az2_tenant_ext_gw
    dns_server     = var.dns_server
    ntp_server     = var.ntp_server
    timezone       = var.timezone
    admin_user     = var.uname
    admin_password = var.upassword

    #app1_net        = "${local.app1_net}"
    #app1_net_gw     = "${local.app1_net_gw}"
  }
}

# Render tenant DO declaration
resource "local_file" "az2_tenant_do_file" {
  content  = data.template_file.az2_tenantCluster_do_json.rendered
  filename = "${path.module}/${var.az2_tenantCluster_do_json}"
}

/*
# tenant TS Declaration
data "template_file" "tenant_ts_json" {
  template = "${file("${path.module}/tsCloudwatch_ts.tpl.json")}"

  vars = {
    aws_region = var.aws_region
  }
}
# Render tenant TS declaration
resource "local_file" "tenant_ts_file" {
  content  = "${data.template_file.tenant_ts_json.rendered}"
  filename = "${path.module}/${var.tenant_ts_json}"
}

# tenant LogCollection AS3 Declaration
data "template_file" "tenant_logs_as3_json" {
  template = "${file("${path.module}/tsLogCollection_as3.tpl.json")}"

  vars = {

  }
}
# Render tenant LogCollection AS3 declaration
resource "local_file" "tenant_logs_as3_file" {
  content  = "${data.template_file.tenant_logs_as3_json.rendered}"
  filename = "${path.module}/${var.tenant_logs_as3_json}"
}
*/

/*
# tenant AS3 Declaration
data "template_file" "tenant_as3_json" {
  template = "${file("${path.module}/tenant_as3.tpl.json")}"

  vars = {
    backendvm_ip   = aws_instance.bastionHost[0].private_ip
    asm_policy_url = "${var.asm_policy_url}"
  }
}

# Render tenant AS3 declaration
resource "local_file" "tenant_as3_file" {
  content  = "${data.template_file.tenant_as3_json.rendered}"
  filename = "${path.module}/${var.tenant_as3_json}"
}
*/

resource "null_resource" "az1_tenantF5_DO" {
  depends_on = [aws_instance.az1_tenant_bigip]
  # Running DO REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -k -X ${var.rest_do_method} https://${aws_instance.az1_tenant_bigip.public_ip}${var.rest_do_uri} -u ${var.uname}:${var.upassword} -d @${var.az1_tenantCluster_do_json}
      x=1; while [ $x -le 30 ]; do STATUS=$(curl -k -X GET https://${aws_instance.az1_tenant_bigip.public_ip}/mgmt/shared/declarative-onboarding/task -u ${var.uname}:${var.upassword}); if ( echo $STATUS | grep "OK" ); then break; fi; sleep 10; x=$(( $x + 1 )); done
      sleep 120
    EOF
  }
}

resource "null_resource" "az2_tenantF5_DO" {
  depends_on = [aws_instance.az2_tenant_bigip]
  # Running DO REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -k -X ${var.rest_do_method} https://${aws_instance.az2_tenant_bigip.public_ip}${var.rest_do_uri} -u ${var.uname}:${var.upassword} -d @${var.az2_tenantCluster_do_json}
      x=1; while [ $x -le 30 ]; do STATUS=$(curl -k -X GET https://${aws_instance.az2_tenant_bigip.public_ip}/mgmt/shared/declarative-onboarding/task -u ${var.uname}:${var.upassword}); if ( echo $STATUS | grep "OK" ); then break; fi; sleep 10; x=$(( $x + 1 )); done
      sleep 120
    EOF
  }
}

/*
resource "null_resource" "tenantF5_TS" {
  depends_on = ["null_resource.az1_tenantF5_DO", "null_resource.az2_tenantF5_DO"]
  # Running CF REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -H 'Content-Type: application/json' -k -X POST https://${aws_instance.az1_tenant_bigip.public_ip}${var.rest_ts_uri} -u ${var.uname}:${var.upassword} -d @${var.tenant_ts_json}
    EOF
  }
}

resource "null_resource" "tenantF5_TS_LogCollection" {
  depends_on = ["null_resource.tenantF5_TS"]
  # Running CF REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -H 'Content-Type: application/json' -k -X POST https://${aws_instance.az1_tenant_bigip.public_ip}${var.rest_as3_uri} -u ${var.uname}:${var.upassword} -d @${var.tenant_logs_as3_json}
    EOF
  }
}
*/
