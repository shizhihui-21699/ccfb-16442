# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "isms"

class IdentityMapperTest < Minitest::Test
  def base_mappings
    [
      { source_system: "gitlab", external_login: "alice", person_id: "E1", confidence: 1.0, source: "sso" },
      { source_system: "gitlab", external_login: "maybe", person_id: "E2", confidence: 0.4, source: "guess" }
    ]
  end

  def test_confident_mapping_resolves
    mapper = ISMS::Domain::IdentityMapper.new(mappings: base_mappings)
    pid, conf = mapper.resolve(source_system: "gitlab", external_login: "alice")
    assert_equal "E1", pid
    assert_equal 1.0, conf
    assert_empty mapper.pending_review
  end

  def test_unknown_login_goes_to_review_queue_not_silently_guessed
    mapper = ISMS::Domain::IdentityMapper.new(mappings: base_mappings)
    pid, = mapper.resolve(source_system: "gitlab", external_login: "ghost")
    assert_nil pid
    assert_equal 1, mapper.pending_review.size
    assert_match(/无映射记录/, mapper.pending_review.first[:reason])
  end

  def test_low_confidence_mapping_rejected
    mapper = ISMS::Domain::IdentityMapper.new(mappings: base_mappings)
    pid, = mapper.resolve(source_system: "gitlab", external_login: "maybe")
    assert_nil pid
    assert_match(/置信度/, mapper.pending_review.first[:reason])
  end

  def test_string_keys_from_yaml_are_supported
    # 回归：YAML 加载产生字符串键，早期版本用符号键取值导致全部解析为 nil
    mappings = [{ "source_system" => "gitlab", "external_login" => "alice",
                  "person_id" => "E1", "confidence" => 1.0, "source" => "sso" }]
    mapper = ISMS::Domain::IdentityMapper.new(mappings: mappings)
    pid, = mapper.resolve(source_system: "gitlab", external_login: "alice")
    assert_equal "E1", pid
  end

  def test_login_matching_is_case_insensitive
    mapper = ISMS::Domain::IdentityMapper.new(mappings: base_mappings)
    pid, = mapper.resolve(source_system: "gitlab", external_login: "ALICE")
    assert_equal "E1", pid
  end
end
