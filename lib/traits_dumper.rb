# Generate a ZIP file containing a dump of the traits graphdb.
# The ZIP contains four CSV files:
#
#   traits.csv   - one row per Trait node
#   metadata.csv - one row per Metadata node
#   pages.csv    - one row per Page node
#   terms.csv    - one row per Term node
#   inferred.csv - one row per inferred_trait relationship
#
# This script run as a rake command (see rakelib/dump_traits.rake).  The 
#     graphdb is accessed directly, using neography.
#
# See documentation in doc/trait-bank-dumps.md.
#
# Parameters for API mode only:
#   server (SERVER) - base URL for the server to contact.  Should
#      end with a /.  Default https://eol.org/.
#   token (TOKEN) - authentication token for web API
#
# If the script is interrupted, it can be run again and it will use
# files created on a previous run, if the previous run was in the same
# calendar month.  This is a time saving measure.

# E.g. get traits for Felidae (7674):
#
# Run it directly from the shell
# ID=7674 CHUNK=20000 TOKEN=`cat api.token` ZIP=felidae.zip ruby -r ./lib/traits_dumper.rb -e TraitsDumper.main
#
# Run it as a 'rake' task
# ID=7674 CHUNK=20000 time bundle exec rake dump_traits:dump

# Thanks to Bill Tozier https://github.com/vaguery for code review;
# but he is not to be held responsible for anything you see here.

require 'csv'
require 'fileutils'
require 'zip'

# These are required if we want to be an HTTP client:
require 'net/http'
require 'json'
require 'cgi'

require 'graph'
require 'paginator'

# An instance of the TraitsDumper class is sort of like a 'session'
# for producing a ZIP file.  Its state of all the parameters needed to
# harvest and write the required information.  The actual state for
# the session, however, resides in files in the file system.

class TraitsDumper

  def self.dump(graph, dest, clade_page_id = nil, chunksize = nil, tempdir = nil)
    new(graph, chunksize, tempdir).dump_traits(dest, clade_page_id)
  end

  # Store parameters in instance so they don't have to be passed
  # around everywhere.
  # The query_fn takes a CQL query as input, executes it, and returns
  # a result set.  The result set is returned in the idiosyncratic
  # form delivered by neo4j.  The implementation of the query_fn might
  # use neography, or the EOL web API, or any other method for
  # executing CQL queries.

  def initialize(graph, chunksize = 10000, tempdir = nil)
    @graph = graph
    @chunksize = chunksize
    @tempdir = tempdir
    @paginator = Paginator.new(graph)
  end

  # dest is name of zip file to be written, or nil for default
  def dump_traits(dest, clade_page_id = nil)
    clade = (clade_page_id ? Integer(clade_page_id) : nil) # kludge
    @tempdir = @tempdir || File.join("/tmp", default_basename(clade))
    puts `date`
    paths = [emit_terms,
             emit_pages(clade),
             emit_inferred(clade),
             emit_traits(clade),
             emit_metadatas(clade)]
    if not paths.include?(nil)
      dest = "." unless dest
      dest = File.join(dest, default_basename(clade) + ".zip") if
        File.directory?(dest)
      write_zip(paths, dest) 
    end
    puts `date`
  end

  # Mostly-unique tag based on current month and clade id
  def default_basename(id)
    month = DateTime.now.strftime("%Y%m")
    tag = id || "all"
    "traits_#{tag}_#{month}"
  end

  # Write a zip file containing a specified set of files.
  def write_zip(paths, dest)
    File.delete(dest) if File.exists?(dest)
    Zip::File.open(dest, Zip::File::CREATE) do |zipfile|
      directory = "trait_bank"
      zipfile.mkdir(directory)
      paths.each do |path|
        if path
          name = File.basename(path)
          STDERR.puts "storing #{name} into zip file"
          zipfile.add(File.join(directory, name), path)
        end
      end
      # Put file name on its own line for easier cut/paste
      STDERR.puts dest
    end
  end

  # Return query fragment for lineage (clade, page, ID) restriction,
  # if there is one.
  def transitive_closure_part(clade)
    if clade
      ", (page)-[:parent*]->(clade:Page {page_id: #{clade}})"
    else
      ""
    end
  end

  # All of the following emit_ methods return the path to the
  # generated file, or nil if any query failed (e.g. timed out)

  #---- Query: Terms

  def emit_terms

    # Many Term nodes have 'uri' properties that are not URIs.  Would it 
    # be useful to filter those out?  It's about 2% of the nodes.

    # I'm not sure where there exist multiple Term nodes for a single URI?

    terms_query =
     "MATCH (r:Term)
      OPTIONAL MATCH (r)-[:parent_term]->(parent:Term)
      RETURN r.uri, r.name, r.type, parent.uri
      ORDER BY r.uri"
    # To add, maybe: trait_row_count, distinct_page_count, synonym_of,
    #   object_for_predicate
    #   and many others... definition, comment, attribution, section_ids, ...
    terms_keys = ["uri", "name", "type", "parent_uri"]
    supervise_query(terms_query, terms_keys, "terms.csv")
    # returns nil on failure (e.g. timeout)
  end

  #---- Query: Pages (taxa)
  # Ray Ma has pointed out that the traits dump contains page ids
  # that are not in this set, e.g. for interaction traits.

  def emit_pages(clade)
    pages_query =
     "MATCH (page:Page) #{transitive_closure_part(clade)}
      WHERE page.canonical IS NOT NULL
      OPTIONAL MATCH (page)-[:parent]->(parent:Page)
      RETURN page.page_id, parent.page_id, page.rank, page.canonical"
    pages_keys = ["page_id", "parent_id", "rank", "canonical"] #fragile
    supervise_query(pages_query, pages_keys, "pages.csv")
    # returns nil on failure (e.g. timeout)
  end

  #---- Query: Traits (trait records)

  def emit_traits(clade)
    filename = "traits.csv"
    csv_path = File.join(@tempdir, filename)
    if File.exist?(csv_path)
      STDERR.puts "reusing previously created #{csv_path}"
      return csv_path
    end
    # Matching the keys used in the tarball if possible (even when inconsistent)
    # E.g. should "predicate" be "predicate_uri" ?
    traits_keys = ["eol_pk", "page_id", "resource_pk", "resource_id",
                   "source", "scientific_name", "predicate",
                   "object_page_id", "value_uri",
                   "normal_measurement", "normal_units_uri", "normal_units",
                   "measurement", "units_uri", "units",
                   "literal",
                   "method", "remarks", "sample_size", "name_en",
                   "citation"]
    predicates = list_trait_predicates
    STDERR.puts "#{predicates.length} trait predicate URIs"
    files = []
    fails = []
    dir = "traits.csv.predicates"

    for i in 0..predicates.length do
      predicate = predicates[i]
      STDERR.puts "Predicate #{i} = #{predicate}" if i % 25 == 0
      next if is_attack?(predicate)
      traits_query =
       "MATCH (t:Trait)<-[:trait]-(page:Page)
              #{transitive_closure_part(clade)}
        WHERE page.canonical IS NOT NULL
        MATCH (t)-[:predicate]->(predicate:Term {uri: '#{predicate}'})
        OPTIONAL MATCH (t)-[:supplier]->(r:Resource)
        OPTIONAL MATCH (t)-[:object_term]->(obj:Term)
        OPTIONAL MATCH (t)-[:object_page]->(obj_page:Page)
        OPTIONAL MATCH (t)-[:normal_units_term]->(normal_units:Term)
        OPTIONAL MATCH (t)-[:units_term]->(units:Term)
        RETURN t.eol_pk, page.page_id, r.resource_pk, r.resource_id,
               t.source, t.scientific_name, predicate.uri,
               obj_page.page_id, obj.uri,
               t.normal_measurement, normal_units.uri, t.normal_units, 
               t.measurement, units.uri, t.units, 
               t.literal,
               t.method, t.remarks, t.sample_size, t.name_en,
               t.citation"
      # TEMPDIR/{traits,metadata}.csv.predicates/
      ppath = supervise_query(traits_query, traits_keys,
                              "traits.csv.predicates/#{i}.csv")
      # ppath is nil on failure (e.g. timeout)
      ppath ? files.push(ppath) : fails.push(ppath)
    end
    if fails.empty?
      @paginator.assemble_chunks(files, csv_path)
    else
      STDERR.puts "** Deferred due to exception(s): traits.csv"
      nil
    end
  end

  # Filtering by term type seems to be only an optimization, and
  # it's looking wrong to me.
  # What about the other types - association and value ?

  # term.type can be: measurement, association, value, metadata

  # MATCH (pred:Term) WHERE (:Trait)-[:predicate]->(pred) RETURN pred.uri LIMIT 20

  def list_trait_predicates
    predicates_query =
      'MATCH (pred:Term)
      WHERE (pred)<-[:predicate]-(:Trait)
      RETURN DISTINCT pred.uri
      LIMIT 10000'
    run_query(predicates_query)["data"].map{|row| row[0]}
  end

  # Prevent injection attacks (quote marks in URIs and so on)
  def is_attack?(uri)
    if /\A[\p{Alnum}:#_=?#& \/\.-]*\Z/.match(uri)
      false
    else
      STDERR.puts "** scary URI: '#{uri}'"
      true
    end
  end

  #---- Query: Metadatas
  # Structurally similar to traits.  I'm duplicating code because Ruby
  # style does not encourage procedural abstraction (or at least, I
  # don't know how one properly share code here, in idiomatic Ruby).

  def emit_metadatas(clade)
    filename = "metadata.csv"
    csv_path = File.join(@tempdir, filename)
    if File.exist?(csv_path)
      STDERR.puts "reusing previously created #{csv_path}"
      return csv_path
    end
    metadata_keys = ["eol_pk", "trait_eol_pk", "predicate", "value_uri",
                     "measurement", "units_uri", "literal"]
    predicates = list_metadata_predicates
    STDERR.puts "#{predicates.length} metadata predicate URIs"
    files = []
    fails = []
    for i in 0..predicates.length do
      predicate = predicates[i]
      next if is_attack?(predicate)
      STDERR.puts "#{i} #{predicate}" if i % 25 == 0
      metadata_query = 
        "MATCH (m:MetaData)<-[:metadata]-(t:Trait),
              (t)<-[:trait]-(page:Page)
              #{transitive_closure_part(clade)}
        WHERE page.canonical IS NOT NULL
        MATCH (m)-[:predicate]->(predicate:Term),
              (t)-[:predicate]->(metadata_predicate:Term {uri: '#{predicate}'})
        OPTIONAL MATCH (m)-[:object_term]->(obj:Term)
        OPTIONAL MATCH (m)-[:units_term]->(units:Term)
        RETURN m.eol_pk, t.eol_pk, predicate.uri, obj.uri, m.measurement, units.uri, m.literal"
      ppath = supervise_query(metadata_query, metadata_keys,
                              "metadata.csv.predicates/#{i}.csv")
      # ppath is nil on failure (e.g. timeout)
      ppath ? files.push(ppath) : fails.push(ppath)
    end
    if fails.empty?
      @paginator.assemble_chunks(files, csv_path)
    else
      STDERR.puts "** Deferred due to exception(s): metadata.csv"
      nil
    end
  end

  # Returns list (array) of URIs

  def list_metadata_predicates
    predicates_query =
     'MATCH (pred:Term)
      WHERE (pred)<-[:predicate]-(:MetaData)
      RETURN DISTINCT pred.uri
      LIMIT 10000'
    run_query(predicates_query)["data"].map{|row| row[0]}
  end

  def emit_inferred(clade)
    filename = "inferred.csv"
    csv_path = File.join(@tempdir, filename)
    if File.exist?(csv_path)
      STDERR.puts "reusing previously created #{csv_path}"
      return csv_path
    end
    inferred_keys = ["page_id", "inferred_trait"]
    inferred_query = 
       "MATCH (page:Page)-[:inferred_trait]->(trait:Trait)
              #{transitive_closure_part(clade)}
        RETURN page.page_id AS page_id, trait.eol_pk AS trait"
    supervise_query(inferred_query, inferred_keys, filename)
  end

  # -----

  # supervise_query: generate a set of 'chunks', then put them
  # together into a single .csv file.

  # A chunk (or 'part,' I use these words interchangeably here) is
  # the result set of a single cypher query.  The queries are in a
  # single supervise_query call are all the same, except for the value
  # of the SKIP parameter.

  # The reason for this is that the result sets for some queries are
  # too big to capture with a single query, due to timeouts or other
  # problems.

  # Each chunk is placed in its own file.  If a chunk file already
  # exists the query is not repeated - the results from the previous
  # run are used directly without verification.

  # filename (where to put the .csv file) is interpreted relative to
  # @tempdir.  The return value is full pathname to csv file (which is
  # created even if empty), or nil if there was any kind of failure.

  def supervise_query(query, columns, filename)
    csv_path = File.join(@tempdir, filename)
    @paginator.supervise_query(query, columns, @chunksize, csv_path)
  end

  # Run a single CQL query using the method provided (could be
  # neography, HTTP, ...)

  def run_query(cql)
    @graph.run_query(cql)
  end

end
