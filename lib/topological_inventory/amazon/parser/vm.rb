module TopologicalInventory::Amazon
  class Parser
    module Vm
      def parse_vms(instance, scope)
        uid      = instance.id
        name     = get_from_tags(instance.tags, :name) || uid
        flavor   = lazy_find(:flavors, :source_ref => instance.instance_type) if instance.instance_type
        stack_id = get_from_tags(instance.tags, "aws:cloudformation:stack-id")
        stack    = lazy_find(:orchestration_stacks, :source_ref => stack_id) if stack_id

        vm = TopologicalInventoryIngressApiClient::Vm.new(
          :source_ref          => uid,
          :uid_ems             => uid,
          :name                => name,
          :power_state         => parse_vm_power_state(instance.state),
          :flavor              => flavor,
          :mac_addresses       => parse_network(instance)[:mac_addresses],
          :source_region       => lazy_find(:source_regions, :source_ref => scope[:region]),
          :subscription        => lazy_find_subscription(scope),
          :orchestration_stack => stack,
        )

        collections[:vms].data << vm
        parse_vm_security_groups(instance)
        parse_tags(:vms, uid, instance.tags)
        ec2_classic_network_adapters_and_ips(instance, scope)
      end

      private

      def parse_network(instance)
        network = {
          :fqdn                 => instance.public_dns_name,
          :private_ip_address   => instance.private_ip_address,
          :public_ip_address    => instance.public_ip_address,
          :mac_addresses        => [],
          :private_ip_addresses => [],
          :public_ip_addresses  => [],
        }

        (instance.network_interfaces || []).each do |interface|
          network[:mac_addresses] << interface.mac_address
          interface.private_ip_addresses.each do |private_ip|
            network[:private_ip_addresses] << private_ip.private_ip_address
            network[:public_ip_addresses] << private_ip&.association&.public_ip if private_ip&.association&.public_ip
          end
        end

        network
      end

      def parse_vm_security_groups(instance)
        (instance.security_groups || []).each do |sg|
          collections[:vm_security_groups].data << TopologicalInventoryIngressApiClient::VmSecurityGroup.new(
            :vm             => lazy_find(:vms, :source_ref => instance.id),
            :security_group => lazy_find(:security_groups, :source_ref => sg.group_id),
          )
        end
      end

      def ec2_classic_network_adapters_and_ips(instance, scope)
        return if instance.vpc_id

        collections[:network_adapters].data << TopologicalInventoryIngressApiClient::NetworkAdapter.new(
          :source_ref          => instance.instance_id,
          :device              => lazy_find(:vms, :source_ref => instance.instance_id),
          :mac_address         => nil,
          :orchestration_stack => nil,
          :source_region       => lazy_find(:source_regions, :source_ref => scope[:region]),
          :subscription        => nil
        )

        collections[:ipaddresses].data << TopologicalInventoryIngressApiClient::Ipaddress.new(
          :source_ref      => "#{instance.instance_id}______#{instance.private_ip_address}",
          :ipaddress       => instance.private_ip_address,
          :network_adapter => lazy_find(:network_adapters, :source_ref => instance.instance_id),
          :source_region   => lazy_find(:source_regions, :source_ref => scope[:region]),
          :extra           => {
            :primary          => true,
            :private_dns_name => instance.private_dns_name,
          },
          :subnet          => nil,
          :kind            => "private",
        )

        if instance.public_ip_address
          collections[:ipaddresses].data << TopologicalInventoryIngressApiClient::Ipaddress.new(
            :source_ref      => instance.public_ip_address,
            :ipaddress       => instance.public_ip_address,
            :network_adapter => lazy_find(:network_adapters, :source_ref => instance.instance_id),
            :source_region   => lazy_find(:source_regions, :source_ref => scope[:region]),
            :subnet          => nil,
            :kind            => "public",
            :extra           => {
              :private_ip_address => instance.private_ip_address,
            }
          )
        end
      end

      def parse_vm_power_state(state)
        case state&.name
        when "pending"
          "suspended"
        when "running"
          "on"
        when "shutting-down", "stopping", "shutting_down"
          "powering_down"
        when "terminated"
          "terminated"
        when "stopped"
          "off"
        else
          "unknown"
        end
      end
    end
  end
end
