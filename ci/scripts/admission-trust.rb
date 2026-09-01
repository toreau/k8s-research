#!/usr/bin/env ruby
# admission-trust.rb — admission signer policy consistency validator.
#
# Derives the canonical admission subjectRegExp from ci/trusted-builders.yaml
# (the promotion trust set) and requires
# cluster/attestations/values-trust-policies.yaml to contain exactly that
# admission identity. Fail-closed: any schema/format/consistency violation
# exits non-zero with no success output.
#
# This is CONFIGURATION CONSISTENCY validation (candidate tree), NOT promotion
# authorization. Promotion authorization stays base-derived in trust-config.
#
# Usage: ruby ci/scripts/admission-trust.rb
#        TRUSTED_BUILDERS=... ruby ci/scripts/admission-trust.rb
#        ADMISSION_VALUES=... ruby ci/scripts/admission-trust.rb
require 'yaml'

trust_file = ENV.fetch('TRUSTED_BUILDERS', 'ci/trusted-builders.yaml')
values_file = ENV.fetch('ADMISSION_VALUES', 'cluster/attestations/values-trust-policies.yaml')

BUILDER_WORKFLOW = 'toreau/gh-workflows/.github/workflows/container-build-attest.yml'
# RE2-compatible literal dot character class; no backslash escaping anywhere.
REGEX_PREFIX = '^https://github[.]com/toreau/gh-workflows/[.]github/workflows/container-build-attest[.]yml@'

fail_hard = lambda do |msg|
  warn "admission-trust: #{msg}"
  exit 1
end

# --- trusted-builders.yaml (canonical promotion trust set) -----------------
begin
  trust = YAML.safe_load(File.read(trust_file), aliases: false)
rescue StandardError => e
  fail_hard.call("cannot parse #{trust_file}: #{e.message}")
end
fail_hard.call('trust policy is not an object') unless trust.is_a?(Hash)
fail_hard.call('unsupported/missing version (expected version: 1)') unless trust['version'] == 1

builders = trust['builders']
fail_hard.call('builders missing or not an object') unless builders.is_a?(Hash) && !builders.empty?
container = builders['container']
fail_hard.call("builder 'container' missing") unless container.is_a?(Hash)

workflow = container['workflow']
fail_hard.call('workflow missing or not a string') unless workflow.is_a?(String) && !workflow.empty?
fail_hard.call("unexpected builder workflow '#{workflow}' (expected #{BUILDER_WORKFLOW})") unless workflow == BUILDER_WORKFLOW

revisions = container['revisions']
fail_hard.call('revisions missing or not an array') unless revisions.is_a?(Array) && !revisions.empty?

shas = []
revisions.each_with_index do |entry, i|
  fail_hard.call("revisions[#{i}] is not an object") unless entry.is_a?(Hash)
  sha = entry['sha']
  sha = sha.to_s unless sha.is_a?(String)
  fail_hard.call("revisions[#{i}].sha missing or not a string") unless sha.is_a?(String) && !sha.empty?
  fail_hard.call("revisions[#{i}].sha '#{sha}' is not an exact lowercase 40-hex SHA") unless sha =~ /\A[0-9a-f]{40}\z/
  shas << sha
end
fail_hard.call('duplicate revision SHAs') unless shas.uniq.length == shas.length

# Deterministic canonical regex, revision order = trust-file order.
tail = shas.length == 1 ? shas.first : "(#{shas.join('|')})"
canonical_regex = "#{REGEX_PREFIX}#{tail}$"

# --- values-trust-policies.yaml (admission signer policy) -------------------
begin
  values = YAML.safe_load(File.read(values_file), aliases: false)
rescue StandardError => e
  fail_hard.call("cannot parse #{values_file}: #{e.message}")
end
fail_hard.call('policy is not an object') unless values.is_a?(Hash)
policy = values['policy']
fail_hard.call('policy missing or not an object') unless policy.is_a?(Hash)
fail_hard.call('policy.enabled is not true') unless policy['enabled'] == true
fail_hard.call('policy.organization must be absent (subjectRegExp is the signer model)') if policy.key?('organization')
fail_hard.call('policy.repository must be absent (subjectRegExp is the signer model)') if policy.key?('repository')

sre = policy['subjectRegExp']
fail_hard.call('policy.subjectRegExp missing or not a string') unless sre.is_a?(String) && !sre.empty?
fail_hard.call("subjectRegExp mismatch:\n  expected: #{canonical_regex}\n  actual:   #{sre}") unless sre == canonical_regex

puts "admission-trust: builder=#{workflow} revisions=#{shas.length} " \
     "subjectRegExp=#{canonical_regex} admission trust consistency: OK"
