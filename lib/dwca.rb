# Darwin Core archive management / manipulation

require 'fileutils'
require 'nokogiri'
require 'open-uri'

require 'table'
require 'property'
require 'system'

class Dwca

  def initialize(dwca_workspace, dwca_path: nil, dwca_url: nil)
    @dwca_workspace = dwca_workspace
    @dwca_path = dwca_path
    @dwca_url = dwca_url      # where the dwca is stored on the Internet
    @tables = nil
  end

  def get_workspace
    unless Dir.exist?(@dwca_workspace)
      puts "Creating directory #{@dwca_workspace}"
      FileUtils.mkdir_p(@dwca_workspace) 
    end
    @dwca_workspace
  end

  def get_unpacked_loc
    File.join(@dwca_workspace, "unpacked")
  end

  # Where the DwCA file is stored in local file system
  def get_dwca_path
    return @dwca_path if @dwca_path
    if @dwca_url
      ext = @dwca_url.end_with?('.zip') ? 'zip' : 'tgz'
      File.join(@dwca_workspace, "dwca.#{ext}")
    else
      zip = File.join(@dwca_workspace, "dwca.zip")
      return zip if File.exists?(zip)
      tgz = File.join(@dwca_workspace, "dwca.tgz")
      return zip if File.exists?(tgz)
      raise "No DWCA_PATH or DWCA_URL was specified / present"
    end
  end

  def get_dwca_url
    @dwca_url || raise("No DWCA_URL was specified")
  end

  # Ensure that the unpack/ directory is populated from the archive file.

  def ensure_unpacked
    dir = get_unpacked_loc
    return dir if File.exists?(File.join(dir, "meta.xml"))

    # Files aren't there.  Ensure that the archive is present locally,
    # then unpack it.

    unpack_archive(ensure_archive_local_copy(dir))
    # We can delete the zip file afterwards if we want... won't be needed
  end

  def ensure_archive_local_copy(dir)
    path = get_dwca_path
    url = get_dwca_url

    # Use existing archive if it's there
    if url_valid?(url) && File.exist?(path) && File.size(path).positive?
      raise "Using previously downloaded archive.  rm -r #{get_workspace} to force reload."
    else
      System.get_from_internet(url, path)
    end

    @dwca_path
  end

  def url_valid?(dwca_url)
    return false unless dwca_url
    # Reuse previous file only if URL matches
    file_holding_url = File.join(@dwca_workspace, "dwca_url")
    valid = false
    if File.exists?(file_holding_url)
      old_url = File.read(file_holding_url)
      if old_url == dwca_url
        valid = true 
      else
        STDERR.puts "Different URL this time!"
      end
    end
  end

  # Adapted from harvester app/models/drop_dir.rb
  # File is either something.tgz or something.zip
  def unpack_archive(archive_file)
    dest = ensure_unpacked
    dir = File.dirname(dest)
    FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
                      
    temp = File.join(get_workspace, "tmp")
    FileUtils.mkdir_p(temp) unless Dir.exist?(temp)

    ext = File.extname(archive_file)
    if ext.casecmp('.tgz').zero?
      untgz(archive_file, temp)
    elsif ext.casecmp('.zip').zero?
      unzip(archive_file, temp)
    else
      raise("Unknown file extension: #{basename}#{ext}")
    end
    source = tuck(temp)
    if File.exists?(dest)
      puts "Removing #{dest}"
      `rm -rf #{dest}` 
    end
    puts "Moving #{source} to #{dest}"
    FileUtils.mv(source, dest)
    if File.exists?(temp)
      puts "Removing #{temp}"
      `rm -rf #{temp}`
    end
    dest
  end

  def untgz(archive_file, dir)
    res = `cd #{dir} && tar xvzf #{archive_file}`
  end

  def unzip(archive_file, dir)
    # NOTE: -u for "update and create if necessary"
    # NOTE: -q for "quiet"
    # NOTE: -o for "overwrite files WITHOUT prompting"
    res = `cd #{dir} && unzip -quo #{archive_file}`
  end

  # Similar to `flatten` in harvester app/models/drop_dir.rb
  def tuck(dir)
    if File.exist?(File.join(dir, "meta.xml"))
      dir
    else
      winners = Dir.children(dir).filter do |child|
        cpath = File.join(dir, child)
        (File.directory?(cpath) and
         File.exist?(File.join(cpath, "meta.xml")))
      end
      raise("Cannot find meta.xml in #{dir}") unless winners.size == 1
      winners[0]
    end
  end

  # @tables maps Claes objects to Table objects

  def get_tables
    return @tables if @tables
    ensure_unpacked
    path = File.join(get_unpacked_loc, "meta.xml")
    puts "Processing #{path}"
    @tables = from_xml(path)
    @tables
  end

  def get_table(claes)
    uri = claes.uri
    tables = get_tables
    probe = tables[claes]
    return probe if probe
    raise("No table for class #{claes.name}.")
  end

  # Get the information that we'll need out of the meta.xml file
  # Returns a hash from classes ('claeses') to table elements
  # Adapted from harvester app/models/resource/from_meta_xml.rb self.analyze
  def from_xml(filename)
    doc = File.open(filename) { |f| Nokogiri::XML(f) }
    tables = doc.css('archive table').collect do |table_element|
      row_type = table_element['rowType']    # a URI
      location = table_element.css("location").first.text
      positions = parse_fields(table_element)
      sep = table_element['fieldsTerminatedBy']
      ig = table_element['ignoreHeaderLines']
      Table.new(property_positions: positions,
                location: location,
                path: File.join(get_unpacked_loc, location),
                separator: sep,
                ignore_lines: (ig ? ig.to_i : 0),
                claes: Claes.get(row_type))
    end
    claes_to_table = {}
    # TBD: Complain if a claes has multiple tables???
    tables.each {|table| claes_to_table[table.claes] = table}
    claes_to_table
  end

  # Parse <field> elements, returning hash from Property to 
  # small integer

  def parse_fields(table_element)
    positions_for_this_table = {}
    table_element.css('field').each do |field|
      i = field['index'].to_i
      prop = Property.get(field['term'])
      positions_for_this_table[prop] = i
    end
    positions_for_this_table
  end

end
