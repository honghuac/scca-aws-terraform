/*
# https://github.com/F5Networks/f5-aws-cloudformation/tree/master/supported/failover/across-net/via-api/3nic/existing-stack/byol/
resource "aws_cloudformation_stack" "bigipPAZ" {
	name = "cf${var.tag_name}-PAZ"
	template_url = "${var.bigip_cft}"
	parameters = {
		Vpc = "${aws_vpc.main.id}"
		ntpServer = "${var.ntp_server}"
		bigIpModules = "${var.paz_f5provisioning}"
		provisionPublicIP = "Yes"
		#declarationUrl = "${file("bigip_as3.json")}"
		managementSubnetAz1 = "${aws_subnet.mgmt1.id}"
		managementSubnetAz2 = "${aws_subnet.mgmt2.id}"
		subnet1Az1 = "${aws_subnet.ext1.id}"
		subnet1Az2 = "${aws_subnet.ext2.id}"
		subnet2Az1 = "${aws_subnet.dmzExt1.id}"
		subnet2Az2 = "${aws_subnet.dmzExt2.id}"
		imageName = "AllTwoBootLocations"
		instanceType = "m5.xlarge"
		licenseKey1 = "${var.bigip_lic1}"
		licenseKey2 = "${var.bigip_lic2}"
		sshKey = "${aws_key_pair.main.id}"
		restrictedSrcAddress = "${var.mgmt_asrc[0]}"
		restrictedSrcAddressApp = "0.0.0.0/0"
		timezone = "UTC"
		allowUsageAnalytics = "No"
	}
	capabilities = ["CAPABILITY_IAM"]
}
*/

# Create and attach bigip tmm network interfaces
resource "aws_network_interface" "az1_mgmt" {
  depends_on      = [aws_security_group.sg_ext_mgmt]
  subnet_id       = aws_subnet.az1_mgmt.id
  private_ips     = [var.az1_pazF5.mgmt]
  security_groups = [aws_security_group.sg_ext_mgmt.id]
}

resource "aws_network_interface" "az1_external" {
  depends_on      = [aws_security_group.sg_external]
  subnet_id       = aws_subnet.az1_ext.id
  private_ips     = [var.az1_pazF5.paz_ext_self, var.az1_pazF5.paz_ext_vip]
  security_groups = [aws_security_group.sg_external.id]
}

resource "aws_network_interface" "az1_internal" {
  depends_on      = [aws_security_group.sg_internal]
  subnet_id       = aws_subnet.az1_dmzExt.id
  private_ips     = [var.az1_pazF5.dmz_ext_self, var.az1_pazF5.dmz_ext_vip]
  security_groups = [aws_security_group.sg_internal.id]
}

# Create elastic IP and map to "VIP" on external paz nic
resource "aws_eip" "eip_vip" {
  depends_on                = [aws_network_interface.az1_external]
  vpc                       = true
  network_interface         = aws_network_interface.az1_external.id
  associate_with_private_ip = var.az1_pazF5.paz_ext_vip
}

resource "aws_eip" "eip_az1_mgmt" {
  depends_on                = [aws_network_interface.az1_mgmt]
  vpc                       = true
  network_interface         = aws_network_interface.az1_mgmt.id
  associate_with_private_ip = var.az1_pazF5.mgmt
}

#Big-IP 1
resource "aws_instance" "az1_bigip" {
  depends_on                  = [aws_subnet.az1_mgmt, aws_security_group.sg_ext_mgmt, aws_network_interface.az1_external, aws_network_interface.az1_internal, aws_network_interface.az1_mgmt]
  ami                         = var.ami_f5image_name
  instance_type               = var.ami_paz_f5instance_type
  user_data                   = data.template_file.vm_onboard.rendered
  key_name                    = "kp${var.tag_name}"
  root_block_device {
    delete_on_termination = true
  }
  network_interface {
    device_index = 0
    network_interface_id = aws_network_interface.az1_mgmt.id
  }
  network_interface {
    device_index = 1
    network_interface_id = aws_network_interface.az1_external.id
  }
  network_interface {
    device_index = 2
    network_interface_id = aws_network_interface.az1_internal.id
  }
  provisioner "remote-exec" {
    connection {
      host = "${aws_instance.az1_bigip.public_ip}"
      type = "ssh"
      user = "${var.uname}"
      password = "${var.upassword}"
    }
    when = "create"
    inline = [
      "until [ -f ${var.onboard_log} ]; do sleep 120; done; sleep 120"
    ]
  }
  provisioner "remote-exec" {
    connection {
      host = "${aws_instance.az1_bigip.public_ip}"
      type = "ssh"
      user = "${var.uname}"
      password = "${var.upassword}"
    }
    when = "destroy"
    inline = [
      "echo y | tmsh revoke sys license"
    ]
    on_failure = "continue"
  }

  tags = {
    Name = "${var.tag_name}-${var.az1_pazF5.hostname}"
  }
}



## AZ1 DO Declaration
data "template_file" "az1_paz_do_json" {
  template = "${file("${path.module}/clusterAcrossAZs_do.tpl.json")}"
  vars = {
    #Uncomment the following line for BYOL
    regkey	        = "${var.paz_lic1}"
    banner_color    = "red"
    host1	          = "${var.az1_pazF5.hostname}"
    host2	          = "${var.az2_pazF5.hostname}"
    local_host      = "${var.az1_pazF5.hostname}"
    local_selfip1   = "${var.az1_pazF5.paz_ext_self}"
    local_selfip2   = "${var.az1_pazF5.dmz_ext_self}"
    remote_selfip   = "${var.az2_pazF5.mgmt}"
    mgmt_gw         = "${local.az1_mgmt_gw}"
    gateway	        = "${local.az1_paz_gw}"
    dns_server	    = "${var.dns_server}"
    ntp_server	    = "${var.ntp_server}"
    timezone	      = "${var.timezone}"
    admin_user      = "${var.uname}"
    admin_password  = "${var.upassword}"

    #app1_net        = "${local.app1_net}"
    #app1_net_gw     = "${local.app1_net_gw}"
  }
}
# Render PAZ DO declaration
resource "local_file" "az1_paz_do_file" {
  content     = "${data.template_file.az1_paz_do_json.rendered}"
  filename    = "${path.module}/${var.az1_paz_do_json}"
}


# PAZ LOCAL_ONLY (HaAcrossAZs) Routing configuration
data "template_file" "az1_local_only_tmsh_json" {
  template = "${file("${path.module}/local_only_tmsh.tpl.json")}"
  vars = {
    mgmt_ip     = "${var.az1_pazF5.mgmt}"
    mgmt_gw     = "${local.az1_mgmt_gw}"
    gw	        = "${local.az1_paz_gw}"
  }
}
# Render LOCAL_ONLY (HaAcrossAZs) Routing declaration
resource "local_file" "az1_local_only_tmsh_file" {
  content     = "${data.template_file.az1_local_only_tmsh_json.rendered}"
  filename    = "${path.module}/${var.az1_local_only_tmsh_json}"
}


# Create and attach bigip tmm network interfaces
resource "aws_network_interface" "az2_mgmt" {
  depends_on      = [aws_security_group.sg_ext_mgmt]
  subnet_id       = aws_subnet.az2_mgmt.id
  private_ips     = [var.az2_pazF5.mgmt]
  security_groups = [aws_security_group.sg_ext_mgmt.id]
}

resource "aws_network_interface" "az2_external" {
  depends_on      = [aws_security_group.sg_external]
  subnet_id       = aws_subnet.az2_ext.id
  private_ips     = [var.az2_pazF5.paz_ext_self, var.az2_pazF5.paz_ext_vip]
  security_groups = [aws_security_group.sg_external.id]
}

resource "aws_network_interface" "az2_internal" {
  depends_on      = [aws_security_group.sg_internal]
  subnet_id       = aws_subnet.az2_dmzExt.id
  private_ips     = [var.az2_pazF5.dmz_ext_self, var.az2_pazF5.dmz_ext_vip]
  security_groups = [aws_security_group.sg_internal.id]
}

resource "aws_eip" "eip_az2_mgmt" {
  depends_on                = [aws_network_interface.az2_mgmt]
  vpc                       = true
  network_interface         = aws_network_interface.az2_mgmt.id
  associate_with_private_ip = var.az2_pazF5.mgmt
}

# BigIP 2
resource "aws_instance" "az2_bigip" {
  depends_on                  = [aws_subnet.az2_mgmt, aws_security_group.sg_ext_mgmt, aws_network_interface.az2_external, aws_network_interface.az2_internal, aws_network_interface.az2_mgmt]
  ami                         = var.ami_f5image_name
  instance_type               = var.ami_paz_f5instance_type
  availability_zone           = "${var.aws_region}b"
  user_data                   = data.template_file.vm_onboard.rendered
  key_name                    = "kp${var.tag_name}"
  root_block_device {
    delete_on_termination = true
  }
  network_interface {
    device_index = 0
    network_interface_id = aws_network_interface.az2_mgmt.id
  }
  network_interface {
    device_index = 1
    network_interface_id = aws_network_interface.az2_external.id
  }
  network_interface {
    device_index = 2
    network_interface_id = aws_network_interface.az2_internal.id
  }
  provisioner "remote-exec" {
    connection {
      host = "${aws_instance.az2_bigip.public_ip}"
      type = "ssh"
      user = "${var.uname}"
      password = "${var.upassword}"
    }
    when = "create"
    inline = [
      "until [ -f ${var.onboard_log} ]; do sleep 120; done; sleep 120"
    ]
  }

  provisioner "remote-exec" {
    connection {
      host = "${aws_instance.az2_bigip.public_ip}"
      type = "ssh"
      user = "${var.uname}"
      password = "${var.upassword}"
    }
    when = "destroy"
    inline = [
      "echo y | tmsh revoke /sys license"
    ]
    on_failure = "continue"
  }

  tags = {
    Name = "${var.tag_name}-${var.az2_pazF5.hostname}"
  }
}


## AZ2 DO Declaration
data "template_file" "az2_paz_do_json" {
  template = "${file("${path.module}/clusterAcrossAZs_do.tpl.json")}"
  vars = {
    #Uncomment the following line for BYOL
    regkey	        = "${var.paz_lic2}"
    banner_color    = "red"
    host1	          = "${var.az2_pazF5.hostname}"
    host2	          = "${var.az1_pazF5.hostname}"
    local_host      = "${var.az2_pazF5.hostname}"
    local_selfip1   = "${var.az2_pazF5.paz_ext_self}"
    local_selfip2   = "${var.az2_pazF5.dmz_ext_self}"
    remote_selfip   = "${var.az1_pazF5.mgmt}"
    mgmt_gw         = "${local.az2_mgmt_gw}"
    gateway	        = "${local.az2_paz_gw}"
    dns_server	    = "${var.dns_server}"
    ntp_server	    = "${var.ntp_server}"
    timezone	      = "${var.timezone}"
    admin_user      = "${var.uname}"
    admin_password  = "${var.upassword}"

    #app1_net        = "${local.app1_net}"
    #app1_net_gw     = "${local.app1_net_gw}"
  }
}
# Render PAZ DO declaration
resource "local_file" "az2_paz_do_file" {
  content     = "${data.template_file.az2_paz_do_json.rendered}"
  filename    = "${path.module}/${var.az2_paz_do_json}"
}

# PAZ LOCAL_ONLY (HaAcrossAZs) Routing configuration
data "template_file" "az2_local_only_tmsh_json" {
  template = "${file("${path.module}/local_only_tmsh.tpl.json")}"
  vars = {
    mgmt_ip     = "${var.az2_pazF5.mgmt}"
    mgmt_gw     = "${local.az2_mgmt_gw}"
    gw	        = "${local.az2_paz_gw}"
  }
}
# Render LOCAL_ONLY (HaAcrossAZs) Routing declaration
resource "local_file" "az2_local_only_tmsh_file" {
  content     = "${data.template_file.az2_local_only_tmsh_json.rendered}"
  filename    = "${path.module}/${var.az2_local_only_tmsh_json}"
}

# PAZ TS Declaration
data "template_file" "paz_ts_json" {
  template = "${file("${path.module}/tsCloudwatch_ts.tpl.json")}"

  vars = {
    aws_region  = var.aws_region
    access_key  = var.SP.access_key
	  secret_key  = var.SP.secret_key
  }
}
# Render PAZ TS declaration
resource "local_file" "paz_ts_file" {
  content     = "${data.template_file.paz_ts_json.rendered}"
  filename    = "${path.module}/${var.paz_ts_json}"
}

# PAZ LogCollection AS3 Declaration
data "template_file" "paz_logs_as3_json" {
  template = "${file("${path.module}/tsLogCollection_as3.tpl.json")}"

  vars = {

  }
}
# Render PAZ LogCollection AS3 declaration
resource "local_file" "paz_logs_as3_file" {
  content     = "${data.template_file.paz_logs_as3_json.rendered}"
  filename    = "${path.module}/${var.paz_logs_as3_json}"
}

# PAZ AS3 Declaration
data "template_file" "paz_as3_json" {
  template = "${file("${path.module}/paz_as3.tpl.json")}"

  vars = {
    backendvm_ip    = ""
	  asm_policy_url  = "${var.asm_policy_url}"
  }
}
# Render PAZ AS3 declaration
resource "local_file" "paz_as3_file" {
  content     = "${data.template_file.paz_as3_json.rendered}"
  filename    = "${path.module}/${var.tenant1_paz_as3_json}"
}


resource "null_resource" "az1_pazF5_DO" {
  depends_on	= [aws_instance.az1_bigip]
  # Running DO REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -k -X ${var.rest_do_method} https://${aws_instance.az1_bigip.public_ip}${var.rest_do_uri} -u ${var.uname}:${var.upassword} -d @${var.az1_paz_do_json}
      x=1; while [ $x -le 30 ]; do STATUS=$(curl -k -X GET https://${aws_instance.az1_bigip.public_ip}/mgmt/shared/declarative-onboarding/task -u ${var.uname}:${var.upassword}); if ( echo $STATUS | grep "OK" ); then break; fi; sleep 10; x=$(( $x + 1 )); done
      sleep 120
    EOF
  }
}

resource "null_resource" "az1_pazF5_LOCAL_ONLY_routing" {
  depends_on    = ["null_resource.az1_pazF5_DO"]
  # Running CF REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      x=1; while [ $x -le 30 ]; do STATUS=$(curl -k -X GET https://${aws_instance.az1_bigip.public_ip}/mgmt/shared/declarative-onboarding -u ${var.uname}:${var.upassword}); if ( echo $STATUS | grep "OK" ); then break; fi; echo $STATUS sleep 10; x=$(( $x + 1 )); done
      curl -H 'Content-Type: application/json' -k -X ${var.rest_util_method} https://${aws_instance.az1_bigip.public_ip}${var.rest_tmsh_uri} -u ${var.uname}:${var.upassword} -d @${var.az1_local_only_tmsh_json}
    EOF
  }
}

resource "null_resource" "az2_pazF5_DO" {
  depends_on    = [aws_instance.az2_bigip]
  # Running DO REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -k -X ${var.rest_do_method} https://${aws_instance.az2_bigip.public_ip}${var.rest_do_uri} -u ${var.uname}:${var.upassword} -d @${var.az2_paz_do_json}
      x=1; while [ $x -le 30 ]; do STATUS=$(curl -k -X GET https://${aws_instance.az2_bigip.public_ip}/mgmt/shared/declarative-onboarding/task -u ${var.uname}:${var.upassword}); if ( echo $STATUS | grep "OK" ); then break; fi; sleep 10; x=$(( $x + 1 )); done
      sleep 120
    EOF
  }
}

resource "null_resource" "az2_pazF5_LOCAL_ONLY_routing" {
  depends_on    = ["null_resource.az2_pazF5_DO"]
  # Running CF REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      x=1; while [ $x -le 30 ]; do STATUS=$(curl -k -X GET https://${aws_instance.az2_bigip.public_ip}/mgmt/shared/declarative-onboarding -u ${var.uname}:${var.upassword}); if ( echo $STATUS | grep "OK" ); then break; fi; echo $STATUS sleep 10; x=$(( $x + 1 )); done
      curl -H 'Content-Type: application/json' -k -X ${var.rest_util_method} https://${aws_instance.az2_bigip.public_ip}${var.rest_tmsh_uri} -u ${var.uname}:${var.upassword} -d @${var.az2_local_only_tmsh_json}
    EOF
  }
}

resource "null_resource" "pazF5_TS" {
  depends_on    = ["null_resource.az1_pazF5_LOCAL_ONLY_routing", "null_resource.az2_pazF5_LOCAL_ONLY_routing"]
  # Running CF REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -H 'Content-Type: application/json' -k -X POST https://${aws_instance.az1_bigip.public_ip}${var.rest_ts_uri} -u ${var.uname}:${var.upassword} -d @${var.paz_ts_json}
    EOF
  }
}

resource "null_resource" "pazF5_TS_LogCollection" {
  depends_on    = ["null_resource.pazF5_TS"]
  # Running CF REST API
  provisioner "local-exec" {
    command = <<-EOF
      #!/bin/bash
      curl -H 'Content-Type: application/json' -k -X POST https://${aws_instance.az1_bigip.public_ip}${var.rest_as3_uri} -u ${var.uname}:${var.upassword} -d @${var.paz_logs_as3_json}
    EOF
  }
}