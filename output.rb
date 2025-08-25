# output.rb — writes a real CSV file under /content/ and still prints to STDOUT.
# Columns: Typo Type | Typo Domain | IP | Country | NameServer | MailServer
# Rows: ONLY valid + resolved (A/AAAA present)

require 'csv'
require 'json'
require 'resolv'
require 'fileutils'

begin
  require 'colorize'
rescue LoadError
  class String; def colorize(*); self; end; end
end

class Output
  def initialize(this_domain, keyboard_layout, check_popularity, resolve_domains, show_invalid)
    @domain           = this_domain
    @keyboard_layout  = keyboard_layout
    @check_popularity = check_popularity
    @resolve_domains  = resolve_domains
    @show_invalid     = show_invalid
  end

  # ---------- helpers ----------
  def ensure_trailing_dot(s)
    s = s.to_s.strip
    return "" if s.empty?
    s.end_with?(".") ? s : (s + ".")
  end

  def effective_resolved_a(typo)
    raw = typo.resolved_a.to_s.strip
    return raw unless raw.empty?
    ips = []
    begin
      Resolv::DNS.open do |dns|
        dns.timeouts = 2
        dns.getresources(typo.name.to_s, Resolv::DNS::Resource::IN::A   ).each { |r| ips << r.address.to_s }
        dns.getresources(typo.name.to_s, Resolv::DNS::Resource::IN::AAAA).each { |r| ips << r.address.to_s }
      end
    rescue StandardError; end
    ips.uniq.join(' ')
  end

  def effective_resolved_ns(typo)
    raw = typo.resolved_ns.to_s.strip
    ns  = raw.split(/\s+/).first.to_s
    return ensure_trailing_dot(ns) unless ns.empty?
    begin
      Resolv::DNS.open do |dns|
        dns.timeouts = 2
        recs = dns.getresources(typo.name.to_s, Resolv::DNS::Resource::IN::NS)
        return ensure_trailing_dot(recs.first&.name.to_s) if recs && !recs.empty?
      end
    rescue StandardError; end
    ""
  end

  def effective_resolved_mx(typo)
    raw = typo.resolved_mx.to_s.strip
    mx  = raw.split(/\s+/).first.to_s
    return ensure_trailing_dot(mx) unless mx.empty?
    begin
      Resolv::DNS.open do |dns|
        dns.timeouts = 2
        recs = dns.getresources(typo.name.to_s, Resolv::DNS::Resource::IN::MX)
        if recs && !recs.empty?
          best = recs.min_by { |r| r.preference.to_i }
          return ensure_trailing_dot(best&.exchange.to_s) unless best.nil?
        end
      end
    rescue StandardError; end
    ""
  end

  def filtered_typos
    @domain.typos.select do |t|
      valid = (t.valid_name == true || t.valid_name.to_s.strip.downcase == "true")
      ipstr = effective_resolved_a(t)
      valid && !ipstr.empty?
    end
  end

  # ---- file output helpers ----
  def sanitize_filename(s)
    s.to_s.gsub(/[^\w.\-]+/, "_")
  end

  def default_outfile_path
    ts   = Time.now.utc.strftime("%Y%m%d-%H%M%S")
    base = sanitize_filename(@domain.domain)
    File.join("/content", "#{base}_typos_#{ts}.csv")
  end

  def outfile_path
    (ENV["URLCRAZY_OUTFILE"] && ENV["URLCRAZY_OUTFILE"].strip != "" && ENV["URLCRAZY_OUTFILE"]) ||
    (ENV["OUTFILE"]         && ENV["OUTFILE"].strip         != "" && ENV["OUTFILE"]) ||
    default_outfile_path
  end

  def write_text_file(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "w") { |f| f.write(contents) }
  end

  # suppress headers in CSV/JSON modes
  def header; end
  def hostnames_to_process; "" end

  private
  def print_output(*args); args.each { |a| $stdout.print(a.to_s) }; end
  def puts_output(str=""); $stdout.puts(str.to_s); end
  def warn_output(str=""); $stderr.puts(str.to_s); end
end

# ---------------- HUMAN TABLE (clean, no dashed lines) ----------------
class OutputHuman < Output
  def table
    headings = ["Typo Type","Typo Domain","IP","Country","NameServer","MailServer"]
    rows = filtered_typos.map do |t|
      ip = effective_resolved_a(t)
      country = if t.respond_to?(:country_a) && t.country_a && t.country_a.any?
                  "#{t.country_a.last} (#{t.country_a.first})"
                else
                  ""
                end
      [t.type.to_s, t.name.to_s, ip, country, effective_resolved_ns(t), effective_resolved_mx(t)]
    end

    widths = headings.each_with_index.map do |h,i|
      [h.length, rows.map { |r| r[i].to_s.length }.max || 0].max + 2
    end
    headings.each_with_index { |h,i| print_output h; print_output " " * (widths[i]-h.length) }
    puts_output

    rows.each do |r|
      r.each_with_index do |cell,i|
        s = cell.to_s
        print_output s
        print_output " " * (widths[i]-s.length)
      end
      puts_output
    end
    puts_output
  end
end

# ---------------- CSV (writes to file under /content + prints to STDOUT) ----------------
class OutputCSV < Output
  def table
    headings = ["Typo Type","Typo Domain","IP","Country","NameServer","MailServer"]

    csv = CSV.new("",
      col_sep: ",",
      row_sep: "\n",
      force_quotes: true,
      write_headers: true,
      headers: headings
    )

    filtered_typos.each do |t|
      ip = effective_resolved_a(t)
      country = if t.respond_to?(:country_a) && t.country_a && t.country_a.any?
                  "#{t.country_a.last} (#{t.country_a.first})"
                else
                  ""
                end
      csv << [ t.type.to_s, t.name.to_s, ip, country, effective_resolved_ns(t), effective_resolved_mx(t) ]
    end

    data = csv.string

    # 1) Write to a real file under /content
    path = outfile_path
    write_text_file(path, data)
    warn_output "CSV written to: #{path}"

    # 2) Still print CSV to STDOUT to preserve CLI behavior
    puts_output data
  end
end

# ---------------- JSON (optional, prints to STDOUT only) ----------------
class OutputJSON < Output
  def table
    items = filtered_typos.map do |t|
      {
        type:       t.type.to_s,
        name:       t.name.to_s,
        ip:         effective_resolved_a(t),
        country:    (t.respond_to?(:country_a) && t.country_a && t.country_a.any?) ? "#{t.country_a.last} (#{t.country_a.first})" : "",
        nameserver: effective_resolved_ns(t),
        mailserver: effective_resolved_mx(t)
      }
    end
    puts_output({ domain: @domain.domain, tld: @domain.tld, items: items }.to_json)
  end
end
