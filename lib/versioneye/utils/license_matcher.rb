require 'nokogiri'
require 'narray'
require 'tf-idf-similarity'
require 'json'

class LicenseMatcher

  attr_reader :corpus, :licenses, :model, :url_index, :rules, :spdx_ids, :custom_ids, :spdx_rules

  DEFAULT_CORPUS_FILES_PATH = 'data/spdx_licenses/plain'
  CUSTOM_CORPUS_FILES_PATH  = 'data/custom_licenses' # Where to look up non SPDX licenses
  LICENSE_JSON_FILE         = 'data/spdx_licenses/licenses.json'

  def get_rule_ids
    ids = {}
    @rules.keys.each do |the_key|
      the_id = the_key.to_s.downcase.strip
      ids[the_id] = the_key
    end

    ids
  end


  def log
    Versioneye::Log.instance.log
  end


  def initialize(files_path = DEFAULT_CORPUS_FILES_PATH, license_json_file = LICENSE_JSON_FILE)
    spdx_ids, spdx_docs = read_corpus(files_path)
    custom_ids, custom_docs = read_corpus(CUSTOM_CORPUS_FILES_PATH)

    @licenses = spdx_ids + custom_ids
    @spdx_ids = spdx_ids
    @custom_ids = custom_ids
    @corpus = spdx_docs + custom_docs

    licenses_json_doc = read_json_file license_json_file
    @url_index = read_license_url_index(licenses_json_doc)
    @model = TfIdfSimilarity::BM25Model.new(@corpus, :library => :narray)
    @rules = get_rules
    @spdx_rules = init_spdx_rules
    true
  end


  def match_text(text, n = 3)
    clean_text = safe_encode(text)
    test_doc   = TfIdfSimilarity::Document.new(clean_text, {:id => "test"})

    mat1 = @model.instance_variable_get(:@matrix)
    mat2 = doc_tfidf_matrix(test_doc)

    n_docs = @model.documents.size
    dists = []
    n_docs.times do |i|
      dists << [i, cos_sim(mat1[i, true], mat2)]
    end

    top_matches = dists.sort {|a,b| b[1] <=> a[1]}.take(n)

    # Translate doc numbers to id
    top_matches.reduce([]) do |acc, doc_id_and_score|
      doc_id, score = doc_id_and_score
      acc << [ @model.documents[doc_id].id, score ]
      acc
    end
  end


  def match_html(html_doc, n = 3)
    doc = Nokogiri.HTML(html_doc)
    return [] if doc.nil?

    body_txt = doc.xpath(
      '//p | //h1 | //h2 | //h3 | //h4 | //h5 | //h6 | //em | // strong |//td |//pre
      |//li[not(@id) and not(@class) and not(a)]'
    ).text.to_s.strip

    if body_txt.empty?
      log.error "match_html: document didnt pass noise filter, will use whole body content"
      body_txt = doc.xpath('//body').text.to_s.strip
    end

    if body_txt.empty?
      log.info "match_html: didnt find enough text from html_doc: #{html_doc}"
      return []
    end

    match_text(body_txt, n)
  end


  # Matches License.url with urls in Licenses.json and returns tuple [spdx_id, score]
  def match_url(the_url)
    the_url = the_url.to_s.strip
    spdx_id = nil
    @url_index.each do |lic_url, lic_id|
      lic_url = lic_url.to_s.strip.gsub(/https?:\/\//i, '').gsub(/www\./, '') #normalizes urls in the file
      matcher = Regexp.new("^https?:\/\/(www\.)?#{lic_url}.*$", Regexp::IGNORECASE)

      if matcher.match(the_url)
        spdx_id = lic_id
        break
      end
    end

    return [] if spdx_id.nil?

    [spdx_id, 1.0]
  end


  # finds matching regex rules in the license name
  # ps: not very efficient, but good enough to handle special cases;
  # @args:
  #   text - string, a name of license,
  #   early_exit  - boolean, default: true, will only return first match
  # @returns:
  def match_rules(text, early_exit = true)
    matches = []
    text_ = preprocess_text(text) + " " #required to make difference between end of versionNumber and end of string
    ignore_rules = get_ignore_rules()

    #if text is in ignore list, then return same text, but negative score as it's spam
    return [text_, -1] if matches_any_rule?(ignore_rules, text_)

    @rules.each do |spdx_id, rules|
      matching_rule = matches_any_rule?(rules, text_)
      unless matching_rule.nil?
        matches << [spdx_id, 1.0, matching_rule]
        break if early_exit
      end
    end

    matches
  end

  # finds matching SPDX rule that matches with the text
  def match_spdx_rules(text, early_exit = true)
    matches = []
    text_ = preprocess_text(text) + " "

    @spdx_rules.each do |spdx_id, rules|
      matching_rule = matches_any_rule?(rules, text_)
      unless matching_rule.nil?
        matches << [spdx_id, 1.0, matching_rule]
        break if early_exit
      end
    end

    matches
  end

  def preprocess_text(the_text)
    #TODO: stop words
    the_text = text.to_s.strip.gsub(/[\,|\.|\?|\!]/, ' ').gsub(/\s+/, ' ')
  end

  def matches_any_rule?(rules, license_name)
    matching_rule = nil
    rules.each do |rule|
      if rule.match(license_name.to_s)
        matching_rule = rule
        break
      end
    end

    matching_rule
  end


#-- helpers

  # Transforms document into TF-IDF matrix used for comparition
  def doc_tfidf_matrix(doc)
    arr = Array.new(@model.terms.size) do |i|
      the_term = @model.terms[i]
      if doc.term_count(the_term) > 0
        #calc score only for words that exists in the test doc and the corpus of licenses
        model.idf(the_term) * model.tf(doc, the_term)
      else
        0.0
      end
    end

    NArray[*arr]
  end


  # Calculates cosine similarity between 2 TF-IDF vector
  def cos_sim(mat1, mat2)
    length = (mat1 * mat2).sum
    norm   = Math::sqrt((mat1 ** 2).sum) * Math::sqrt((mat2 ** 2).sum)

    ( norm > 0 ? length / norm : 0.0)
  end


  def read_json_file(file_path)
    JSON.parse(File.read(file_path), {symbolize_names: true})
  rescue
    log.info "Failed to read json file `#{file_path}`"
    nil
  end


  # Reads license urls from the license.json and builds a map {url : spdx_id}
  def read_license_url_index(spdx_licenses)
    url_index = {}
    spdx_licenses.each {|lic| url_index.merge! process_spdx_item(lic) }
    url_index
  end


  def process_spdx_item(lic)
    url_index = {}
    lic_id = lic[:id]
    return url_index if lic_id.nil?

    lic[:links].to_a.each {|x| url_index[x[:url]] = lic_id }
    lic[:text].to_a.each {|x| url_index[x[:url]] = lic_id }

    url_index
  end


  # Reads licenses content from the files_path and returns list of texts
  def read_corpus(files_path)
    file_names = get_license_names(files_path)

    docs = file_names.reduce([]) do |acc, file_name|
      content = File.read("#{files_path}/#{file_name}")
      txt = safe_encode(content)
      if txt
        acc << TfIdfSimilarity::Document.new(txt, :id => file_name)
      else
        log.error "read_corpus: failed to encode content of corpus #{files_path}/#{file_name}"
      end

      acc
    end

    [file_names, docs]
  end


  def get_license_names(files_path)
    Dir.entries(files_path).to_a.delete_if {|name| ( name == '.' or name == '..' or name =~ /\w+\.py/i or name =~ /.DS_Store/i )}
  end


  # Returns top-N matching licenses with matching score
  def safe_encode(txt)
    txt.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
  rescue
     "Failed to encode text:\n #{txt}"
    return nil
  end


  # builds regex rules based on the LicenseJSON file
  # rules are using urls, IDS, names and alternative names to build full string matching regexes
  def init_spdx_rules
    spdx_rules = {}

    spdx_json = read_json_file(LICENSE_JSON_FILE)
    unless spdx_json
      raise "init_spdx_rules: failed to read spdx JSON file at #{LICENSE_JSON_FILE}."
    end

    spdx_json.each do |spdx_item|
      spdx_rules[spdx_item[:id]] = build_spdx_item_rules(spdx_item)
    end

    spdx_rules
  end

  def build_spdx_item_rules(spdx_item)
    rules = []
    rules << Regexp.new("\\b#{spdx_item[:id]}\\b".gsub(/\s+/, '\\s'), Regexp::IGNORECASE)
    rules << Regexp.new("\\b#{spdx_item[:name]}\\b".gsub(/\s+/, '\\s'), Regexp::IGNORECASE)
    
    spdx_item[:identifiers].to_a.each do |id|
      rules << Regexp.new("\\b#{id[:identifier]}\\b".gsub(/\s+/, '\\s'), Regexp::IGNORECASE)
    end

    spdx_item[:links].to_a.each do |link|
      rules << Regexp.new("\\b#{link[:url]}\\b".gsub(/\s+/, '\\s'), Regexp::IGNORECASE)
    end

    spdx_item[:other_names].to_a.each do |alt|
      rules << Regexp.new("\\b#{alt[:name]}\\b".gsub(/\s+/, '\\s'), Regexp::IGNORECASE)
    end

    rules
  end

  def get_ignore_rules
    [
      /\bProprietary\b/i, /\bOther\/Proprietary\b/i, /\bLICEN[C|S]E\.\w{2,8}\b/i,
      /^LICEN[C|S]ING\.\w{2,8}\b/i, /^COPYING\.\w{2,8}/i,
      /\bDFSG\s+APPROVED\b/i, /\bSee\slicense\sin\spackage\b/i,
      /\bFree\s+for\s+non[-]?commercial\b/i, /\bFree\s+To\s+Use\b/i,
      /\bFree\sFor\sHome\sUse\b/i, /\bFree\s+For\s+Educational\b/i,
      /^Freely\s+Distributable$/i, /^COPYRIGHT\s+\d{2,4}/i,
      /^Copyright\s+\(c\)\s+\d{2,4}\b/i, /^COPYRIGHT$/i, /^COPYRIGHT\.\w{2,8}\b/i,
      /^\(c\)\s+\d{2,4}\d/,
      /^LICENSE$/i, /^FREE$/i, /^See\sLicense$/i, /^TODO$/i, /^FREEWARE$/i,
      /^All\srights\sreserved$/i, /^COPYING$/i, /^OTHER$/i, /^NONE$/i, /^DUAL$/i,
      /^KEEP\s+IT\s+REAL$/i, /\bSee\s+LICENSE\s+file\b/i, /^LICEN[C|S]E$/i,
      /^PUBLIC$/i, /^see file LICENSE$/i, /^__license__$/i,
      /^GNU$/i, /^GNU[-|\s]?v3$/i, /^OSI\s+Approved$/i, /^OSI$/i,
      /^https?:\/\/github.com/i
    ]
  end

  def get_rules
    {
      "AAL"           => [/\bAAL\b/i, /\bAAL\s+License\b/i,
                          /\bAttribution\s+Assurance\s+License\b/i],
      "AFL-1.1"       => [/\bAFL[-|v]?1[^\.]\b/i, /\bafl[-|v]?1\.1\b/i],
      "AFL-1.2"       => [/\bAFL[-|v]?1\.2\b/i],
      "AFL-2.0"       => [/\bAFL[-|v]?2[^\.]\b/i, /\bAFL[-|v]?2\.0\b/i],
      "AFL-2.1"       => [/\bAFL[-|v]?2\.1\b/i],
      "AFL-3.0"       => [
                          /\bAFL[-|v]?3/i, /\bAcademic\s+Free\s+License\b/i, /^AFL$/i,
                          /\bhttps?:\/\/opensource\.org\/licenses\/academic\.php\b/i
                          ],
      "AGPL-1.0"      => [
                          /\bAGPL[-|v|_|\s]?1\.0\b/i,
                          /\bAGPL[-|v|_|\s]1\b/i , /\bAGPL[_|-|v]?2\b/i,
                          /\bAffero\s+General\s+Public\s+License\s+[v]?1\b/i,
                          /\bAGPL\s(?!(v|\d))/i #Matches only AGPL, but not AGPL v1, AGPL 1.0 etc
                          ],
      "AGPL-3.0"      => [
                          /\bAGPL[-|_|\s]?3\.0\b/i, /\bAGPL[-|v|_]?3/i,
                          /\bAPGLv?3\b/i, #some packages has typos
                          /\bGNU\s+Affero\s+General\s+Public\s+License\s+[v]?3/i,
                          /\bAFFERO\sGNU\sPUBLIC\sLICENSE\sv3\b/i,
                          /\bGnu\sAffero\sPublic\sLicense\sv3+?\b/i,
                          /\bAFFERO GENERAL PUBLIC\b/,
                          /^AFFERO$/i
                         ],
      "Apache-1.0"    => [/\bAPACHE[-|_|\s]?v?1[^\.]/i, /\bAPACHE[-|\s]?v?1\.0\b/i],
      "Apache-1.1"    => [/\bAPACHE[-|_|\s]?v?1\.1\b/i],
      "Apache-2.0"    => [
                          /\bAPACHE[-|_|\s]?v?2\b/i, /\bAPACHE\s+2\.0\b/i,
                          /\bAPL\s+2\.0\b/i, /\bAPL[\.|-|v]?2\b/i, /\bASL\s+2\.0\b/i,
                          /\bASL[-|v|\s]?2\b/i, /\bAPACHE\s+LICENSE\s+VERSION\s+2\.0\b/i,
                          /\bALv2\b/i, /\bASF[-|\s]?2\.0\b/i, /\bAPACHE[^-v_\s]\b/i, /^ASL$/i,
                          /\bASL\s+v?\.2\.0\b/i
                         ],
      "APL-1.0"       => [/\bapl[-|_|\s]?v?1\b/i, /\bAPL[-|_|\s]?v?1\.0\b/i, /^APL$/i],
      "APSL-1.0"      => [/\bAPSL[-|_|\s]?v?1\.0\b/i, /\bAPSL[-|_|\s]?v?1(?!\.)\b/i, /\bAPPLE\s+PUBLIC\s+SOURCE\b/i],
      "APSL-1.1"      => [/\bAPSL[-|_|\s]?v?1\.1\b/i],
      "APSL-1.2"      => [/\bAPSL[-|_|\s]?v?1\.2\b/i],
      "APSL-2.0"      => [/\bAPSL[-|_|\s]?v?2\.0\b/i, /\bAPSL[-|_|\s]?v?2\b/i],

      "Artistic-1.0-Perl" => [/\bArtistic[-|_|\s]?v?1\.0\-Perl\b/i, /\bPerlArtistic\b/i],
      "Artistic-1.0"  => [/\bartistic[-|_|\s]?v?1\.0\b/i, /\bartistic[-|_|\s]?v?1\b/i],
      "Artistic-2.0"  => [/\bARTISTIC[-|_|\s]?v?2\.0\b/i, /\bartistic[-|_|\s]?v?2\b/i,
                          /\bARTISTIC\s+LICENSE\b/i, /\bARTISTIC\b/i],
      "Beerware"      => [
                          /\bBEERWARE\b/i, /\bBEER\s+LICEN[c|s]E\b/i,
                          /\bBEER[-|\s]WARE\b/i, /^BEER\b/i,
                          /\bBuy\ssnare\sa\sbeer\b/i,
                          /\bWISKY[-|_|\s]?WARE\b/i
                         ],
      "BSD-2-Clause"  => [/\bBSD[-|_|\s]?v?2\b/i, /^FREEBSD\b/i, /^OPENBSD\b/i],
      "BSD-3-Clause"  => [/\bBSD[-|_|\s]?v?3\b/i, /\bBSD[-|\s]3[-\s]CLAUSE\b/i,
                          /\bBDS[-|_|\s]3[-|\s]CLAUSE\b/i, /^BDS$/i, /^various\/BSDish$/],
      "BSD-4-Clause"  => [
                          /\bBSD[-|_|\s]?v?4/i, /\bBSD\b/i, /\bBSD\s+LICENSE\b/i,
                          /\bBSD-4-CLAUSE\b/i,
                          /^http:\/\/en\.wikipedia\.org\/wiki\/BSD_licenses$/i
                         ],
      "BSL-1.0"       => [
                          /\bBSL[-|_|\s]?v?1\.0\b/i, /\bbsl[-|_|\s]?v?1\b/i, /^BOOST\b/i,
                          /\bBOOST\s+SOFTWARE\s+LICENSE\b/i,
                          /\bBoost\sLicense\s1\.0\b/i
                         ],
      "CC0-1.0"       => [
                          /\bCC0[-|_|\s]?v?1\.0\b/i, /\bCC0[-|_|\s]?v?1\b/i,
                          /\bCC[-|\s]?[0|o]\b/i, /\bCreative\s+Commons\s+0\b/i
                         ],
      "CC-BY-1.0"     => [/\bCC.BY.v?1\.0\b/i, /\bCC.BY.v?1\b/i, /^CC[-|_|\s]?BY$/i],
      "CC-BY-2.0"     => [/\bCC.BY.v?2\.0\b/i, /\bCC.BY.v?2(?!\.)\b/i],
      "CC-BY-2.5"     => [/\bCC.BY.v?2\.5\b/i],
      "CC-BY-3.0"     => [/\bCC.BY.v?3\.0\b/i, /\bCC.BY.v?3\b/i],
      "CC-BY-4.0"     => [
                          /^CC[-|\s]?BY[-|\s]?v?4\.0$/i, /\bCC.BY.v?4\b/i, /\bCC.BY.4\.0\b/i,
                          /\bCREATIVE\s+COMMONS\s+ATTRIBUTION\s+[v]?4\.0\b/i,
                          /\bCREATIVE\s+COMMONS\s+ATTRIBUTION\b/i
                         ],
      "CC-BY-SA-1.0"  => [/\bCC[-|\s]BY.SA.v?1\.0\b/i, /\bCC[-|\s]BY.SA.v?1\b/i],
      "CC-BY-SA-2.0"  => [/\bCC[-|\s]BY.SA.v?2\.0\b/i, /\bCC[-|\s]BY.SA.v?2(?!\.)\b/i],
      "CC-BY-SA-2.5"  => [/\bCC[-|\s]BY.SA.v?2\.5\b/i],
      "CC-BY-SA-3.0"  => [/\bCC[-|\s]BY.SA.v?3\.0\b/i, /\bCC[-|\s]BY.SA.v?3\b/i,
                          /\bCC3\.0[-|_|\s]BY.SA\b/i,
                          /\bhttp:\/\/creativecommons\.org\/licenses\/by-sa\/3\.0\/\b/i],
      "CC-BY-SA-4.0"  => [
                          /CC[-|\s]BY.SA.v?4\.0$/i, /\bCC[-|\s]BY.SA.v?4\b/i,
                          /CCSA-4\.0/i
                         ],
      "CC-BY-NC-1.0"  => [/\bCC[-|\s]BY.NC[-|\s]?v?1\.0\b/i, /\bCC[-|\s]BY.NC[-|\s]?v?1\b/i],
      "CC-BY-NC-2.0"  => [/\bCC[-|\s]BY.NC[-|\s]?v?2\.0\b/i],
      "CC-BY-NC-2.5"  => [/\bCC[-|\s]BY.NC[-|\s]?v?2\.5\b/i],
      "CC-BY-NC-3.0"  => [/\bCC[-|\s]BY.NC[-|\s]?v?3\.0\b/i, /\bCC.BY.NC[-|\s]?v?3\b/i,
                          /\bCreative\s+Commons\s+Non[-]?Commercial[,]?\s+3\.0\b/i],
      "CC-BY-NC-4.0"  => [/\bCC[-|\s]BY.NC[-|\s|_]?v?4\.0\b/i, /\bCC.BY.NC[-|\s|_]?v?4\b/i],
      "CC-BY-NC-SA-1.0" => [ /\bCC[-|\s+]BY.NC.SA[-|\s+]v?1\.0\b/i,
                             /\bCC[-|\s+]BY.NC.SA[-|\s+]v?1\b/i
                           ],
      "CC-BY-NC-SA-2.0" =>  [/\bCC[-|\s]?BY.NC.SA[-|\s]?v?2\.0\b/i],
      "CC-BY-NC-SA-2.5" =>  [/\bCC[-|\s]?BY.NC.SA[-|\s]?v?2\.5\b/i],
      "CC-BY-NC-SA-3.0" =>  [
                              /\bCC[-|\s]?BY.NC.SA[-|\s]?v?3\.0\b/i,
                              /\bCC[-|\s]?BY.NC.SA[-|\s]?v?3(?!\.)\b/i,
                              /\bBY[-|\s]NC[-|\s]SA\sv?3\.0\b/i,
                              /^http:\/\/creativecommons.org\/licenses\/by-nc-sa\/3.0\/us\/$/i
                            ],
      "CC-BY-NC-SA-4.0" => [/\bCC[-|\s]?BY.NC.SA[-|\s]?v?4\.0\b/i,
                            /\bCC[-|_|\s]BY.NC.SA[-\s]?v?4(?!\.)\b/i],

      "CC-BY-ND-1.0"  => [/\bCC[-|\s]BY.ND[-|\s]?v?1\.0\b/i],
      "CC-BY-ND-2.0"  => [/\bCC[-|\s]BY.ND[-|\s]?v?2\.0\b/i],
      "CC-BY-ND-2.5"  => [/\bCC[-|\s]BY.ND[-|\s]?v?2\.5\b/i],
      "CC-BY-ND-3.0"  => [/\bCC[-|\s]BY.ND[-|\s]?v?3\.0\b/i],
      "CC-BY-ND-4.0"  => [/\bCC[-|\s]BY.ND[-|\s]?v?4\.0\b/i],

      "CDDL-1.0"      => [/\bCDDL[-|_|\s]?v?1\.0\b/i, /\bCDDL[-|_|\s]?v?1\b/i, /^CDDL$/i,
                          /\bCDDL\s+LICEN[C|S]E\b/i,
                          /\bCOMMON\sDEVELOPMENT\sAND\sDISTRIBUTION\sLICENSE\b/i
                         ],
      "CECILL-B"      => [/\bCECILL[-|_|\s]?B\b/i],
      "CECILL-C"      => [/\bCECILL[-|_|\s]?C\b/i],
      "CECILL-1.0"    => [
                          /\bCECILL[-|\s|_]?v?1\.0\b/i,  /\bCECILL[-|\s|_]?v?1\b/i,
                          /^CECILL$/i, /\bCECILL\s+v?1\.2\b/i,
                          /^http:\/\/www\.cecill\.info\/licences\/Licence_CeCILL-C_V1-en.html$/i,
                          /\bhttp:\/\/www\.cecill\.info\b/i
                         ],
      "CECILL-2.1"    => [
                          /\bCECILL[-|_|\s]?2\.1\b/i, /\bCECILL[\s|_|-]?v?2\b/i,
                          /\bCECILL\sVERSION\s2\.1\b/i
                         ],
      "CPL-1.0"       => [
                            /\bCPL[-|\s|_]?v?1\.0\b/i, /\bCPL[-|\s|_]?v?1\b/i,
                            /\bCommon\s+Public\s+License\b/i, /^CPL$/i
                          ],
      "D-FSL-1.0"     => [
                            /\bD-?FSL[-|_|\s]?v?1\.0\b/i, /\bD-?FSL[-|\s|_]?v?1\b/,
                            /\bGerman\sFREE\sSOFTWARE\b/i,
                            /\bDeutsche\sFreie\sSoftware\sLizenz\b/i
                          ],
      "ECL-1.0"       => [ /\bECL[-|\s|_]?v?1\.0\b/i, /\bECL[-|\s|_]?v?1\b/i ],
      "ECL-2.0"       => [
                          /\bECL[-|\s|_]?v?2\.0\b/i, /\bECL[-|\s|_]?v?2\b/i, 
                          /\bEDUCATIONAL\s+COMMUNITY\s+LICENSE[,]?\sVERSION\s2\.0\b/i
                         ],
      "EFL-1.0"       => [/\bEFL[-|\s|_]?v?1\.0\b/i, /\bEFL[-|\s|_]?v?1\b/i ],
      "EFL-2.0"       => [
                          /\bEFL[-|\s|_]?v?2\.0\b/i,  /\bEFL[-|\s|_]?v?2\b/i,
                          /\bEiffel\sForum\sLicense,?\sversion\s2/i
                         ],
      "EPL-1.0"       => [
                          /\bEPL[-|\s|_]?v?1\.0\b/i, /\bEPL[-|\s|_]?v?1\b/i, /\bEPL\b/,
                          /\bECLIPSE\s+PUBLIC\s+LICENSE\s+[v]?1\.0\b/i,
                          /\bECLIPSE\s+PUBLIC\s+LICENSE\b/i,
                          /^ECLIPSE$/i
                         ],
      "EUPL-1.0"      => [/\b[\(]?EUPL[-|\s]?v?1\.0[\)]?\b/i],
      "EUPL-1.1"      => [
                          /\b[\(]?EUPL[-|\s]?v?1\.1[\)]?\b/i,
                          /\bEUROPEAN\s+UNION\s+PUBLIC\s+LICENSE\s+1\.1\b/i,
                          /^EUPL$/i
                         ],
      "GPL-1.0"       => [
                          /\bGPL[-|\s|_]?v?1\.0\b/i, /\bGPL[-|\s|_]?v?1\b/i, 
                          /\bGNU\sPUBLIC\sLICEN[S|C]E\sv?1\b/i
                         ],
      "GPL-2.0"       => [
                          /\bGPL[-|\s|_]?v?2\.0/i, /\bGPL[-|\s|_]?v?2\b/i, /\bGPL\s+[v]?2\b/i,
                          /\bGNU\s+PUBLIC\s+LICENSE\s+2\.0\b/i,
                          /\bGNU\s+PUBLIC\s+License\sV?2\b/i,
                          /\bGNU\s+GPL\s+v2\b/i, /^GNUv?2\b/i, /^GLPv2\b/,
                          /\bWhatever\slicense\sPlone\sis\b/i
                         ],
      "GPL-3.0"       => [
                          /\bGPL[-|\s|_]?v?3\.0\b/i, /\bGPL[-|\s|_]?v?3\b/i, /\bGPL\s+3\b/i,
                          /\bGNU\s+GENERAL\s+PUBLIC\s+License\s+[v]?3\b/i,
                          /\bGNU\sPublic\sLicense\sv?3\.0\b/i,
                          /\bGNU\s+PUBLIC\s+LICENSE\s+v?3\b/i,
                          /\bGnu\sPublic\sLicense\sversion\s3\b/i,
                          /\bGNU\s+PUBLIC\s+v3\+?\b/i,
                          /\b[\(]?GPL[\)]?\b/i, /\bGNU\s+PL\s+[v]?3\b/i,
                          /\bGLPv3\b/i, /\bGNU3\b/i, /GPvL3/i,
                          /\bGNU\sGLP\sv?3\b/i
                         ],

      "ISC"           => [/\bISC\s+LICENSE\b/i, /\b[\(]?ISCL[\)]?\b/i, /\bISC\b/i,
                          /\^ICS$/i],
      "JSON"          => [/\bJSON\s+LICENSE\b/i],
      "LGPL-2.0"      => [/\bLGPL[-|\s|_]?v?2\.0\b/i, /\bLGPL[-|\s|_]?v?2(?!\.)\b/i ],
      "LGPL-2.1"      => [/\bLGPL[-|\s|_]?v?2\.1\b/i],
      "LGPL-3.0"      => [/\bLGPL[-|\s|_]?v?3\b/i, /\bLGPL[-|\s|_]?v?3\.0\b/i,
                          /\b[\(]?LGPL[\)]?/i, /\bLGLP[\s|-|v]?3\.0\b/i, /^LPLv3$/,
                          /\bLESSER\s+GENERAL\s+PUBLIC\s+License\s+[v]?3\b/i,
                          /^http:\/\/www\.gnu\.org\/copyleft\/lesser.html$/i
                         ],
      "MirOS"         => [/\bMirOS\b/i],
      "MIT"           => [/\bMIT\s+LICEN[S|C]E\b/i, /\bMIT\b/i, /\bEXPAT\b/i],
      "MPL-1.0"       => [/\bMPL[-|\s|\_]?v?1\.0\b/i, /\bMPL[-|\s|\_]?v?1(?!\.)\b/i ],
      "MPL-1.1"       => [/\bMPL[-|\s|\_]?v?1\.1\b/i],
      "MPL-2.0"       => [
                          /\bMPL[-|\s|\_]?v?2\.0\b/i, /\bMPL[-|\s|\_]?v?2\b/i, 
                          /\bMOZILLA\s+PUBLIC\s+LICENSE\s+2\.0\b/i,
                          /\bMOZILLA\s+PUBLIC\s+LICENSE[,]?\s+version\s+2\.0\b/i,
                          /\b[\(]?MPL\s+2\.0[\)]?\b/
                         ],
      "MS-PL"         => [/\bMS-?PL\b/i],
      "MS-RL"         => [/\bMS-?RL\b/i, /\bMSR\-LA\b/i],
      "NCSA"          => [/\bNCSA\s+License\b/i, /\bIllinois\/NCSA\sOpen\sSource\b/i, /\bNCSA\b/i ],
      "NGPL"          => [/\bNGPL\b/i],
      "NPOSL-3.0"     => [/\bNPOSL[-|\s|\_]?v?3\.0\b/i, /\bNPOSL[-|\s|\_]?v?3\b/],
      "OFL-1.0"       => [/\bOFL[-|\s|\_]?v?1\.0\b/i, /\bOFL[-|\s|\_]?v?1(?!\.)\b/i,
                          /\bSIL\s+OFL\s+1\.0\b/i],
      "OFL-1.1"       => [/\bOFL[-|\s|\_]?v?1\.1\b/i, /\bSIL\s+OFL\s+1\.1\b/i],

      "OSL-1.0"       => [/\bOSL[-|\s|\_]?v?1\.0\b/i, /\b\OSL[-|\s|\_]?v?1(?!\.)\b/i],
      "OSL-2.0"       => [/\bOSL[-|\s|\_]?v?2\.0\b/i, /\bOSL[-|\s|\_]?v?2(?!\.)\b/i],
      "OSL-2.1"       => [/\bOSL[-|\s|\_]?v?2\.1\b/i],
      "OSL-3.0"       => [/\bOSL[-|\s|\_]?v?3\.0\b/i, /\bOSL[-|\s|\_]?v?3(?!\.)\b/i],

      "PostgreSQL"    => [/\bPostgreSQL\b/i],
      "Python-2.0"    => [
                          /\bPython[-|\s|\_]?v?2\.0\b/i, /\bPython[-|\s|\_]?v?2(?!\.)\b/i,
                          /\bPSF[-|\s|\_]?v?2\b/i, /\bPSFL\b/i, /\bPSF\b/i,
                          /\bPython\s+Software\s+Foundation\b/i,
                          /\bPython\b/i, /\bPSL\b/i,
                          /^http:\/\/www\.opensource\.org\/licenses\/PythonSoftFoundation\.php$/i
                         ],

      "RPL-1.1"       => [/\bRPL[-|\s|_]?v?1\.1\b/i, /\bRPL[-|\s|_]?v?1(?!\.)\b/i],
      "RPL-1.5"       => [
                          /\bRPL[-|\s|_]?v?1\.5\b/i,
                          /\bhttps?:\/\/www\.opensource\.org\/licenses\/rpl\.php\b/i
                         ],

      "QPL-1.0"       => [/\bQPL[-|\s|_]?v?1\.0\b/i,
                          /\bQT\sPublic\sLicen[c|s]e\b/i,
                          /\bPyQ\sGeneral\sLicense\b/i],
      "Sleepycat"     => [/\bSleepyCat\b/i],
      "W3C"           => [/\bW3C\b/i],
      "OpenSSL"       => [/\bOPENSSL\b/i],
      "Unlicense"     => [
                          /\bUNLICENSE\b/i, /^Unlicensed\b/i, /\bNO\s+LICEN[C|S]E\b/i,
                          /^go\sfor\sit\b/i, /^Undecided\b/i
                         ],
      "WTFPL"         => [
                          /\bWTF[P|G]?L\b/i, /\bWTFPL[-|v]?2\b/i,
                          /\bDo\s+whatever\s+you\s+want\b/i, /\bDWTFYW\b/i,
                          /\bDo\s+What\s+the\s+Fuck\s+You\s+Want\b/i, /^DWTFYWT$/i
                         ],
      "WXwindows"     => [/\bwxWINDOWS\s+LIBRARY\sLICEN[C|S]E\b/i, /\bWXwindows\b/i],
      "X11"           => [/\bX11\b/i],
      "ZPL-1.1"       => [/\bZPL[-|\s|\_]?v?1\.1\b/i, /\bZPL[-|\s|\_]?v?1(?!\.)\b/i],
      "ZPL-2.1"       => [
                          /\bZPL[-|\s|_]?v?2\.1\b/i, /\bZPL[-|\s|_]?v?2(?!\.)\b/i, 
                          /\bZPL\s+2\.1\b/i, /\bZOPE\s+PUBLIC\s+LICENSE\b/i
                         ],
      "zlib-acknowledgement" => [/\bZLIB[\/|-|\s]LIBPNG\b/i],
      "ZLIB"          => [/\bZLIB(?!\-)\b/i]

    }
  end

end
