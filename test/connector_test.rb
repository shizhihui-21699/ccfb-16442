# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "isms"

class ConnectorNormalizationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_hr_person_ids_are_populated
    hr = ISMS::Connectors::HRConnector.new(
      source: "hr", data_path: File.join(ROOT, "demo_data/hr_employees.json"),
      expected_interval_hours: 168)
    people = hr.normalize
    assert_equal %w[E1001 E1002 E1003 E1004 E1005], people.map(&:person_id)
    assert people.find { |p| p.person_id == "E1002" }.terminated?
  end

  def test_vendor_specific_disable_terms_are_normalized
    # 回归：GitLab blocked 与 AWS disabled 必须在规范化层统一，
    # 否则引擎只识别其中一种术语，会漏掉整类离职账号
    gl = ISMS::Connectors::RepoConnector.new(
      source: "gitlab", data_path: File.join(ROOT, "demo_data/gitlab.json"),
      expected_interval_hours: 168)
    lisi = gl.accounts.find { |a| a.login == "lisi" }
    assert_includes lisi.status_events.map(&:status), "disabled"
    refute_includes lisi.status_events.map(&:status), "blocked"
  end

  def test_patch_deadline_computed_from_sla_not_source_field
    patcher = ISMS::Connectors::PatchConnector.new(
      source: "cloudpatch", data_path: File.join(ROOT, "demo_data/cloud_patch.json"),
      expected_interval_hours: 336,
      severity_sla_hours: { "critical" => 168, "high" => 360, "medium" => 720, "default" => 720 })
    critical = patcher.normalize.find { |p| p.patch_id == "KB-2026-2201" }
    # 2026-07-10 发布 + 168 小时 = 2026-07-17
    assert_equal Time.utc(2026, 7, 17), critical.deadline_at
  end

  def test_failed_collection_produces_coverage_gap
    aws = ISMS::Connectors::CloudConnector.new(
      source: "aws_iam", data_path: File.join(ROOT, "demo_data/aws_iam.json"),
      expected_interval_hours: 168)
    period = ISMS::TimeRange.new(Time.utc(2026, 7, 1), Time.utc(2026, 10, 1))
    gaps = aws.coverage_gaps(period)
    assert_equal 1, gaps.size
    assert_equal "aws_iam", gaps.first["source"]
    assert_match(/336/, gaps.first["reason"])
  end

  def test_raw_records_are_preserved_verbatim
    gl = ISMS::Connectors::RepoConnector.new(
      source: "gitlab", data_path: File.join(ROOT, "demo_data/gitlab.json"),
      expected_interval_hours: 168)
    raw = gl.raw_records.find { |r| r.raw_id == "gitlab:1002" }
    assert_equal "merge_request", raw.entity_type
    assert raw.payload.key?("approvals") # 原始 payload 不做任何裁剪
  end
end
