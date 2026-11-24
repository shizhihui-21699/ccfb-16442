# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require "time"

module ISMS
  module Evidence
    # 证据包：审核员拿到后可以独立复核每一条结论。
    #
    # 目录结构：
    #   evidence_pack_<period>/
    #     manifest.json            包清单（范围、规则版本、例外、生成时间）
    #     sha256_manifest.txt      每个文件的 SHA-256，封存后任何篡改都可发现
    #     controls/<ID>.json       每个控制的完整评估结果（时间轴 + 证据引用）
    #     raw/<source>/<id>.json   结论引用到的原始系统数据（原样，未加工）
    #     narratives/<ID>.md       给审核员的人工可读叙述
    class Packager
      def initialize(output_dir:, period_label:)
        @dir = File.join(output_dir, "evidence_pack_#{period_label}")
        @period_label = period_label
      end

      def build(results:, raw_records:, rules:, exceptions:, identity_pending:, period:)
        FileUtils.mkdir_p([controls_dir, raw_dir, narratives_dir])

        results.each do |result|
          write_json(File.join(controls_dir, "#{result.control_id}.json"), result.to_h)
          write_narrative(result, rules[result.control_id])
        end

        export_raw_records(raw_records)
        manifest = build_manifest(results, rules, exceptions, identity_pending, period)
        write_json(File.join(@dir, "manifest.json"), manifest)
        write_hash_manifest
        @dir
      end

      private

      def controls_dir; File.join(@dir, "controls"); end
      def raw_dir; File.join(@dir, "raw"); end
      def narratives_dir; File.join(@dir, "narratives"); end

      def export_raw_records(raw_records)
        raw_records.group_by(&:source).each do |source, records|
          source_dir = File.join(raw_dir, source)
          FileUtils.mkdir_p(source_dir)
          records.each do |rec|
            safe = rec.external_id.gsub(%r{[^A-Za-z0-9._-]}, "_")
            write_json(File.join(source_dir, "#{safe}.json"),
                       "raw_id" => rec.raw_id,
                       "source" => rec.source,
                       "entity_type" => rec.entity_type,
                       "observed_at" => rec.observed_at.iso8601,
                       "collected_at" => rec.collected_at.iso8601,
                       "payload" => rec.payload)
          end
        end
      end

      def build_manifest(results, rules, exceptions, identity_pending, period)
        {
          "package" => "ISMS 控制措施持续监测证据包",
          "audit_period" => {
            "start" => period.start_time.iso8601,
            "end" => period.end_time.iso8601
          },
          "generated_at" => Time.now.utc.iso8601,
          "rule_versions" => rules.values.map { |r| { "id" => r["id"], "version" => r["version"] } },
          "control_status_summary" => results.map { |r| { "id" => r.control_id, "status" => r.status } },
          "exceptions_in_scope" => exceptions.map(&:to_h),
          "identity_review_queue" => identity_pending,
          "verification" => "sha256_manifest.txt 列出包内全部文件哈希；如结论与原始数据有出入，以 raw/ 为准"
        }
      end

      def write_narrative(result, rule)
        lines = []
        lines << "# #{result.control_id} #{result.control_name}"
        lines << ""
        lines << "- 标准条款：#{result.standard_ref}"
        lines << "- 规则版本：#{result.rule_version}"
        lines << "- 审核周期结论：**#{status_cn(result.status)}**"
        lines << "- 评估时间（UTC）：#{result.evaluated_at.iso8601}"
        lines << ""
        lines << "## 控制要求"
        lines << rule["description"]
        lines << ""
        lines << "## 周期内符合性时间轴"
        if result.segments.empty?
          lines << "- 本周期内无适用事件（未发现违规，亦无有效证据事件）。"
        else
          result.segments.each do |s|
            r = s["range"]
            lines << "- [#{r['start']} ~ #{r['end']}) #{status_cn(s['status'])}"
            JSON.pretty_generate(s["evidence"]).lines.each { |l| lines << "      #{l.chomp}" }
          end
        end
        lines << ""
        unless result.findings.empty?
          lines << "## 点式发现（#{result.findings.size} 项）"
          result.findings.each do |f|
            lines << "- #{status_cn(f['status'])}：#{f['resource']}（#{f['at']}）"
            JSON.pretty_generate(f["evidence"]).lines.each { |l| lines << "      #{l.chomp}" }
          end
          lines << ""
        end
        unless result.coverage_gaps.empty?
          lines << "## 数据缺口（采集覆盖率不足，需在审核中说明）"
          result.coverage_gaps.each { |g| lines << "- #{g['source']}：#{g['range']['start']} ~ #{g['range']['end']}，#{g['reason']}" }
          lines << ""
        end
        File.write(File.join(narratives_dir, "#{result.control_id}.md"), lines.join("\n") + "\n")
      end

      def status_cn(status)
        { "effective" => "有效", "violated" => "违规", "gap" => "数据缺口",
          "exempted" => "已豁免", "not_applicable" => "不适用" }.fetch(status, status)
      end

      def write_json(path, obj)
        File.write(path, JSON.pretty_generate(obj) + "\n")
      end

      def write_hash_manifest
        files = Dir.glob(File.join(@dir, "**", "*")).select { |f| File.file?(f) }
                    .reject { |f| f.end_with?("sha256_manifest.txt") }.sort
        lines = files.map do |f|
          "#{Digest::SHA256.file(f).hexdigest}  #{f.sub(@dir + File::SEPARATOR, '')}"
        end
        File.write(File.join(@dir, "sha256_manifest.txt"), lines.join("\n") + "\n")
      end
    end
  end
end
