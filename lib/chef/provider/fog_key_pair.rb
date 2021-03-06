require 'chef/provider/lwrp_base'
require 'chef/provisioning/fog_driver/driver'

class Chef::Provider::FogKeyPair < Chef::Provider::LWRPBase

  use_inline_resources

  def whyrun_supported?
    true
  end

  action :create do
    create_key(:create)
  end

  action :delete do
    if current_resource_exists?
      converge_by "delete #{key_description}" do
        case new_driver.compute_options[:provider]
        when 'DigitalOcean'
          compute.destroy_ssh_key(@current_id)
        when 'Joyent'
          compute.delete_key(@current_id)
        when 'OpenStack', 'Rackspace'
          compute.key_pairs.destroy(@current_id)
        else
          compute.key_pairs.delete(new_resource.name)
        end
      end
    end
  end

  def key_description
    "#{new_resource.name} on #{new_driver.driver_url}"
  end

  @@use_pkcs8 = nil # For Ruby 1.9 and below, PKCS can be run

  def create_key(action)
    if @should_create_directory
      Cheffish.inline_resource(self, action) do
        directory run_context.config[:private_key_write_path]
      end
    end

    if current_resource_exists?
      # If the public keys are different, update the server public key
      if !current_resource.private_key_path
        if new_resource.allow_overwrite
          ensure_keys(action)
        else
          raise "#{key_description} already exists on the server, but the private key #{new_private_key_path} does not exist!"
        end
      else
        ensure_keys(action)
      end

      case new_driver.compute_options[:provider]
      when 'DigitalOcean'
        new_fingerprints = [Cheffish::KeyFormatter.encode(desired_key, :format => :openssh)]
      when 'Joyent'
        new_fingerprints = [Cheffish::KeyFormatter.encode(desired_key, :format => :rfc4716md5fingerprint)]
      when 'OpenStack', 'Rackspace'
        new_fingerprints = [Cheffish::KeyFormatter.encode(desired_key, :format => :openssh)]
      else
        # “The nice thing about standards is that you have so many to
        # choose from.” - Andrew S. Tanenbaum
        #
        # The AWS EC2 API uses a PKCS#1 MD5 fingerprint for keys that you
        # import into EC2, but a PKCS#8 SHA1 fingerprint for keys that you
        # generate using its web console. Both fingerprints are different
        # from the familiar RFC4716 MD5 fingerprint that OpenSSH displays
        # for host keys.
        #
        # So compute both possible AWS fingerprints and check if either of
        # them matches.
        new_fingerprints = [Cheffish::KeyFormatter.encode(desired_key, :format => :fingerprint)]
        if RUBY_VERSION.to_f < 2.0
          if @@use_pkcs8.nil?
            begin
              require 'openssl_pkcs8'
              @@use_pkcs8 = true
            rescue LoadError
              Chef::Log.warn("The openssl_pkcs8 gem is not loaded: you may not be able to read key fingerprints created by some cloud providers.  gem install openssl_pkcs8 to fix!")
              @@use_pkcs8 = false
            end
          end
          if @@use_pkcs8
            new_fingerprints << Cheffish::KeyFormatter.encode(desired_private_key,
                                  :format => :pkcs8sha1fingerprint)
          end
        end
      end

      if !new_fingerprints.any? { |f| compare_public_key f }
        if new_resource.allow_overwrite
          converge_by "update #{key_description} to match local key at #{new_resource.private_key_path}" do
            case new_driver.compute_options[:provider]
            when 'DigitalOcean'
              compute.create_ssh_key(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
            when 'Joyent'
              compute.create_key(name: new_resource.name, key: Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
            when 'OpenStack'
              compute.create_key_pair(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
            when 'Rackspace'
              compute.create_keypair(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
            else
              compute.key_pairs.get(new_resource.name).destroy
              compute.import_key_pair(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
            end
          end
        else
          raise "#{key_description} with fingerprint #{@current_fingerprint} does not match local key fingerprint(s) #{new_fingerprints}, and allow_overwrite is false!"
        end
      end
    else
      # Generate the private and/or public keys if they do not exist
      ensure_keys(action)

      # Create key
      converge_by "create #{key_description} from local key at #{new_resource.private_key_path}" do
        case new_driver.compute_options[:provider]
        when 'DigitalOcean'
          compute.create_ssh_key(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
        when 'Joyent'
          compute.create_key(name: new_resource.name, key: Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
        when 'OpenStack'
          compute.create_key_pair(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
        when 'Rackspace'
          compute.create_keypair(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
        else
          compute.import_key_pair(new_resource.name, Cheffish::KeyFormatter.encode(desired_key, :format => :openssh))
        end
      end
    end
  end

  def new_driver
    run_context.chef_provisioning.driver_for(new_resource.driver)
  end

  def ensure_keys(action)
    resource = new_resource
    private_key_path = new_private_key_path
    Cheffish.inline_resource(self, action) do
      private_key private_key_path do
        public_key_path resource.public_key_path
        if resource.private_key_options
          resource.private_key_options.each_pair do |key,value|
            send(key, value)
          end
        end
      end
    end
  end

  def desired_key
    @desired_key ||= begin
      if new_resource.public_key_path
        public_key, format = Cheffish::KeyFormatter.decode(IO.read(new_resource.public_key_path))
        public_key
      else
        desired_private_key.public_key
      end
    end
  end

  def desired_private_key
    @desired_private_key ||= begin
      private_key, format = Cheffish::KeyFormatter.decode(IO.read(new_private_key_path))
      private_key
    end
  end

  def current_resource_exists?
    @current_resource.action != [ :delete ]
  end

  def compare_public_key(new)
    c = @current_fingerprint.split[0,2].join(' ')
    n = new.split[0,2].join(' ')
    c == n
  end

  def compute
    new_driver.compute
  end

  def current_public_key
    current_resource.source_key
  end

  def new_private_key_path
    private_key_path = new_resource.private_key_path || new_resource.name
    if private_key_path.is_a?(Symbol)
      private_key_path
    elsif Pathname.new(private_key_path).relative? && new_driver.config[:private_key_write_path]
      @should_create_directory = true
      ::File.join(new_driver.config[:private_key_write_path], private_key_path)
    else
      private_key_path
    end
  end

  def new_public_key_path
    new_resource.public_key_path
  end

  def load_current_resource
    if !new_driver.kind_of?(Chef::Provisioning::FogDriver::Driver)
      raise 'fog_key_pair only works with fog_driver'
    end
    @current_resource = Chef::Resource::FogKeyPair.new(new_resource.name, run_context)
    case new_driver.provider
    when 'DigitalOcean'
      current_key_pair = compute.ssh_keys.select { |key| key.name == new_resource.name }.first
      if current_key_pair
        @current_id = current_key_pair.id
        @current_fingerprint = current_key_pair ? compute.ssh_keys.get(@current_id).public_key : nil
      else
        current_resource.action :delete
      end
    when 'Joyent'
      current_key_pair = begin
        compute.keys.get(new_resource.name)
      rescue Fog::Compute::Joyent::Errors::NotFound
        nil
      end
      if current_key_pair
        @current_id = current_key_pair.name
        @current_fingerprint = if current_key_pair.respond_to?(:fingerprint)
          current_key_pair.fingerprint
        elsif current_key_pair.respond_to?(:key)
          public_key, format = Cheffish::KeyFormatter.decode(current_key_pair.key)
          public_key.fingerprint
        else
          nil
        end
      else
        current_resource.action :delete
      end
    when 'OpenStack', 'Rackspace'
      current_key_pair = compute.key_pairs.get(new_resource.name)
      if current_key_pair
        @current_id = current_key_pair.name
        @current_fingerprint = current_key_pair ? compute.key_pairs.get(@current_id).public_key : nil
      else
        current_resource.action :delete
      end
    else
      current_key_pair = compute.key_pairs.get(new_resource.name)
      if current_key_pair
        @current_fingerprint = current_key_pair ? current_key_pair.fingerprint : nil
      else
        current_resource.action :delete
      end
    end

    if new_private_key_path && ::File.exist?(new_private_key_path)
      current_resource.private_key_path new_private_key_path
    end
    if new_public_key_path && ::File.exist?(new_public_key_path)
      current_resource.public_key_path new_public_key_path
    end
  end
end
