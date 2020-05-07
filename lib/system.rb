# A system is the topmost description of what's going on.
# Three kinds of things:
#   locations  - places on earth where information can be found
#   resources  - info entities with presences in multiple places
#   assemblies - decisions as to which locations fill roles

# The workspace contains: (ID is always a 'master id')
#   resources/ID/dwca/ID.zip            - web cache  - files loaded from web (esp. DwCAs), keyed by master id
#   resources/ID/dwca/unpacked/foo.tsv  - unpacked dwca area
#   resources/ID/stage/bar.csv          - keyed by master id

require 'assembly'
require 'location'
require 'resource'

class System

  class << self
    def system                  # Singleton, basically...
      return @system if @system
      config = YAML.load(File.read("config/config.yml")) ||
               raise("No configuration found")
      @system = System.new(config)
    end

    def copy_from_internet(url, path)
      workspace = File.basename(path)
      # Download the archive file from Internet if it's not
      `rm -rf #{workspace}`
      STDERR.puts "Copying #{url} to #{path}"
      # This is really clumsy... ought to stream it, or use curl or wget
      open(url, 'rb') do |input|
        File.open(path, 'wb') do |file|
          file.write(input.read)
        end
      end
      raise('Did not download') unless File.exist?(path) && File.size(path).positive?
      File.write(File.join(ws, "url"), url)
      STDERR.puts "... #{File.size(path)} octets"
      path
    end
  end

  def initialize(config)
    @config = config
    @assemblies = {}
    config["assemblies"].each do |tag, config|
      @assemblies[tag] = Assembly.new(self, config, tag)
    end
    @locations = {}
    config["locations"].each do |tag, config|
      @locations[tag] = Location.new(self, config, tag)
    end
    @resources = {}  # by name
    @resources_by_id = {}
    config["resources"].each do |record|
      rec = Resource.new(self, record)
      @resources[record["name"]] = rec
      id = record["id"]
      @resources_by_id[id] = rec if id
    end
  end

  def get_assembly(tag)
    @assemblies[tag]
  end

  def get_location(tag)
    @locations[tag]
  end

  def get_resource(name)
    unless @resources.include?(name)
      @resources[name] = Resource.new(self, {"name" => name})
    end
    @resources[name]
  end

  def get_resource_from_id(id)
    return @resources_by_id[id] if @resources_by_id.include?(id)
    rec = get_location("prod_publishing").get_resource_record_by_id(id)
    @resources[rec["name"]] = Resource.new(self, rec)
  end

  # Master resource id from production publishing site

  def id_for_resource(name)
    if @resources.include?(name)
      @resources[name]["id"]
    else
      loc = get_location("prod_publishing")
      raise "prod_publishing not configured!?" unless loc
      id = loc.id_for_resource(name)
      raise "No id configured for this resource.  Please choose an id
             and put it in config/config.yml." unless id
      id
    end
  end
end
