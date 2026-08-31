#!/usr/bin/env ruby
# trusted-builders.rb — validated extraction of the promotion trust policy
# (ci/trusted-builders.yaml). Emits ONE validated JSON structure:
#   { "workflow": "<owner>/<repo>/.github/workflows/<file>.yml",
#     "revisions": ["<40-hex sha>", ...] }
#
# Fail-closed: any schema/format violation exits non-zero with no output.
# Comments in the trust file are informational only and never part of
# enforcement. Used by the S6/S7 consumer gate callers (pre-PR + final gate).
#
# Usage: TRUSTED_BUILDERS=ci/trusted-builders.yaml ruby ci/scripts/trusted-builders.rb
require 'yaml'
require 'json'

file = ENV.fetch('TRUSTED_BUILDERS', 'ci/trusted-builders.yaml')

fail_hard = lambda do |msg|
  warn "trusted-builders: #{msg}"
  exit 1
end

begin
  data = YAML.safe_load(File.read(file), aliases: false)
rescue StandardError => e
  fail_hard.call("cannot parse #{file}: #{e.message}")
end

fail_hard.call('trust policy is not an object') unless data.is_a?(Hash)
fail_hard.call("unsupported/missing version (expected version: 1)") unless data['version'] == 1

builders = data['builders']
fail_hard.call('builders missing or not an object') unless builders.is_a?(Hash) && !builders.empty?
container = builders['container']
fail_hard.call("builder 'container' missing") unless container.is_a?(Hash)

workflow = container['workflow']
fail_hard.call('workflow missing or not a string') unless workflow.is_a?(String) && !workflow.empty?
# owner/repo/.github/workflows/<file>.yml — no @ref, no whitespace/control, no
# empty owner/repo/path, single workflow filename (GitHub does not allow
# subdirectories under .github/workflows).
unless workflow =~ %r{\A[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/\.github/workflows/[a-zA-Z0-9._-]+\.yml\z}
  fail_hard.call("invalid workflow '#{workflow}' (expected <owner>/<repo>/.github/workflows/<file>.yml, no @ref)")
end
fail_hard.call("workflow '#{workflow}' must not contain an @ref") if workflow.include?('@')

revisions = container['revisions']
fail_hard.call('revisions missing or not an array') unless revisions.is_a?(Array) && !revisions.empty?

shas = []
revisions.each_with_index do |entry, i|
  fail_hard.call("revisions[#{i}] is not an object") unless entry.is_a?(Hash)
  sha = entry['sha']
  # to_s: a legitimate all-digit 40-hex SHA parses as a YAML integer; any
  # non-string scalar is still rejected by the exact 40-hex regex below.
  sha = sha.to_s unless sha.is_a?(String)
  fail_hard.call("revisions[#{i}].sha missing or not a string") unless sha.is_a?(String) && !sha.empty?
  fail_hard.call("revisions[#{i}].sha '#{sha}' is not an exact lowercase 40-hex SHA") unless sha =~ /\A[0-9a-f]{40}\z/
  shas << sha
end
fail_hard.call('duplicate revision SHAs') unless shas.uniq.length == shas.length

puts JSON.generate({ 'workflow' => workflow, 'revisions' => shas })
