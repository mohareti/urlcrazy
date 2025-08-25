# output.rb — clean CSV (commas, one row per record), no banners/lines
# Columns: Typo Type | Typo Domain | IP | Country | NameServer | MailServer
# Rows: ONLY valid + resolved
require 'csv'
require 'json'
require 'resolv'

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
    "" # << blank instead of "."
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
    "" # << blank instead of "."
  end

  def filtered_typos
    @domain.typos.select do |t|
      valid = (t.valid_name == true || t.valid_name.to_s.strip.downcase == "true")
      ipstr = effective_resolved_a(t)
      valid && !ipstr.empty?
    end
  end

  # suppress headers in CSV/JSON modes
  def header; end
  def hostnames_to_process; "" end

  private
  def print_output(*args); args.each { |a| $stdout.print(a.to_s) }; end
  def puts_output(str=""); $stdout.puts(str.to_s); end
end

# ---------------- HUMAN TABLE (no dashed line requirement stated for human;
# we keep a simple, clean table with exact columns) ----------------
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

    # compute widths, print header
    widths = headings.each_with_index.map do |h,i|
      [h.length, rows.map { |r| r[i].to_s.length }.max || 0].max + 2
    end
    headings.each_with_index { |h,i| print_output h; print_output " " * (widths[i]-h.length) }
    puts_output
    # NO dashed line

    # rows
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

# ---------------- CSV (clean: commas, one record per line, no banners) ----------------
class OutputCSV < Output
  def table
    headings = ["Typo Type","Typo Domain","IP","Country","NameServer","MailServer"]

    csv = CSV.new("",
      col_sep: ",",
      row_sep: "\n",      # ensure newline separators (avoid one giant row)
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

    puts_output csv.string
  end
end

# ---------------- JSON (optional) ----------------
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
