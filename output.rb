# output.rb — drop-in replacement
# CSV/JSON: only rows that are syntactically valid AND resolve.
# Also does a local DNS lookup fallback if resolved_a is empty.

require 'csv'
require 'json'
require 'resolv'

begin
  require 'colorize'
rescue LoadError
  class String
    def colorize(*); self; end
  end
end

class Output
  def initialize(this_domain, keyboard_layout, check_popularity, resolve_domains, show_invalid)
    @domain = this_domain
    @keyboard_layout = keyboard_layout
    @check_popularity = check_popularity
    @resolve_domains = resolve_domains
    @show_invalid = show_invalid
  end

  # treat true/false or "true"/"false"
  def truthy?(v)
    v == true || v.to_s.strip.downcase == "true"
  end

  # If urlcrazy didn't fill resolved_a, try resolving here (A+AAAA)
  def effective_resolved_a(typo)
    raw = typo.resolved_a.to_s.strip
    return raw unless raw.empty?

    ips = []
    begin
      Resolv::DNS.open do |dns|
        # short timeouts to avoid blocking
        dns.timeouts = 2
        a_recs    = dns.getresources(typo.name.to_s, Resolv::DNS::Resource::IN::A)
        aaaa_recs = dns.getresources(typo.name.to_s, Resolv::DNS::Resource::IN::AAAA)
        ips += a_recs.map    { |r| r.address.to_s }
        ips += aaaa_recs.map { |r| r.address.to_s }
      end
    rescue StandardError
      # swallow; no IPs → empty
    end
    ips.uniq.join(' ')
  end

  # Keep only syntactically valid names that actually resolve
  def filtered_typos
    @domain.typos.select do |t|
      truthy?(t.valid_name) && !effective_resolved_a(t).to_s.strip.empty?
    end
  end

  def hostnames_to_process; end
  def header; end

  private

  def print_output(*args)
    args.each { |a| $stdout.print(a.to_s) }
  end

  def puts_output(str = "")
    $stdout.puts(str.to_s)
  end
end

class OutputHuman < Output
  def header
    s  = "\n"
    s += "URLCrazy Domain Report\n"
    s += "Domain".ljust(10)   + ": #{@domain.domain}\n"
    s += "Keyboard".ljust(10) + ": #{@keyboard_layout}\n"
    s += "At".ljust(10)       + ": #{Time.now}\n"
    puts_output s
  end

  # show total generated, not filtered count (matches original UX)
  def hostnames_to_process
    "# Please wait. #{@domain.typos.size} hostnames to process\n\n"
  end

  def table
    headings = ["Typo Type","Typo Domain","Valid","Pop","IP","Country","NameServer","MailServer"]
    columns  = Array.new(headings.size) { [] }
    typos    = filtered_typos

    typos.each do |typo|
      columns[0] << typo.type.to_s
      columns[1] << typo.name.to_s
      columns[2] << "true"
      columns[3] << (@check_popularity ? typo.popularity.to_s : "?")
      columns[4] << effective_resolved_a(typo)

      country =
        if typo.country_a && typo.country_a.any?
          "#{typo.country_a.last} (#{typo.country_a.first})"
        else
          ""
        end
      columns[5] << country
      columns[6] << typo.resolved_ns.to_s
      columns[7] << typo.resolved_mx.to_s
    end

    unless @show_invalid
      headings -= ["Valid"]; columns[2] = nil
    end
    unless @check_popularity
      headings -= ["Pop"]; columns[3] = nil
    end
    unless @resolve_domains
      headings -= ["IP","NameServer","MailServer"]
      columns[4] = columns[5] = columns[6] = columns[7] = nil
    end
    headings.compact!
    columns.compact!

    widths = []
    columns.each_with_index do |col, i|
      maxw = ((col.map { |r| r.nil? ? 0 : r.length } << headings[i].length).max) + 2
      widths[i] = maxw
      print_output headings[i].colorize(color: :blue, mode: :bold)
      print_output " " * (maxw - headings[i].length)
    end
    puts_output
    puts_output (widths.map { |w| "-" * w }.join).colorize(:blue)

    columns[0].each_index do |ri|
      columns.each_with_index do |col, ci|
        text = col[ri]
        if columns[0][ri] == "Original"
          print_output text.colorize(color: :green, mode: :bold)
        elsif ri.even?
          print_output text.colorize(mode: :bold)
        else
          print_output text
        end
        print_output " " * (widths[ci] - text.length)
      end
      puts_output
    end
    puts_output
  end
end

class OutputCSV < Output
  # No banner/progress lines in CSV mode
  def header; end
  def hostnames_to_process; "" end

  def table
    headings = ["domain","ip"]

    csv_string = CSV.new("", col_sep: ',', headers: true, force_quotes: true)
    csv_string << headings

    filtered_typos.each do |t|
      csv_string << [ t.name.to_s, effective_resolved_a(t) ]
    end

    puts_output csv_string.string
  end
end

class OutputJSON < Output
  # No banner/progress lines in JSON mode
  def header; end
  def hostnames_to_process; "" end

  def table
    typos = filtered_typos.map do |t|
      { name: t.name, resolved_a: effective_resolved_a(t) }
    end
    puts_output({ domain: @domain.domain, tld: @domain.tld, typos: typos }.to_json)
  end
end
