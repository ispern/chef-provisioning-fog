#   fog:DigitalOcean:<client id>

class Chef
  module Provisioning
    module FogDriver
      module Providers
        class SakuraCloud < FogDriver::Driver
          Driver.register_provider_class('SakuraCloud', FogDriver::Providers::SakuraCloud)

          def creator
            ''
          end

          def self.compute_options_for(provider, id, config)
            new_compute_options = {}
            new_compute_options[:provider] = provider
            new_config = { :driver_options => { :compute_options => new_compute_options }}
            new_defaults = {
              :driver_options => { :compute_options => {} },
              :machine_options => { :bootstrap_options => {} }
            }
            result = Cheffish::MergedConfig.new(new_config, config, new_defaults)

            [result, id]
          end


          def create_ssh_transport(machine_spec, machine_options, server)
            ssh_options = ssh_options_for(machine_spec, machine_options, server)
            username = machine_options[:ssh_username] || machine_spec.location['ssh_username'] || default_ssh_username
            options = {}
            if machine_spec.location[:sudo] || (!machine_spec.location.has_key?(:sudo) && username != 'root')
              options[:prefix] = 'sudo '
            end

            if machine_spec.location['use_private_ip_for_ssh']
              remote_host = server.private_ip_address
            elsif !server.public_ip_address || machine_options[:use_private_ip_for_ssh]
              Chef::Log.warn("Server #{machine_spec.name} has no public floating_ip address.  Using private floating_ip '#{server.private_ip_address}'.  Set driver option 'use_private_ip_for_ssh' => true if this will always be the case ...")
              remote_host = server.private_ip_address
            elsif server.public_ip_address
              remote_host = server.public_ip_address
            else
              raise "Server #{server.id} has no private or public IP address!"
            end

            #Enable pty by default
            options[:ssh_pty_enable] = true
            if machine_spec.location.has_key?('ssh_gateway')
              options[:ssh_gateway] = machine_spec.location['ssh_gateway']
            elsif machine_options[:ssh_gateway]
              options[:ssh_gateway] = machine_options[:ssh_gateway]
            end

            Transport::SSH.new(remote_host, username, ssh_options, options, config)
          end

        end
      end
    end
  end
end