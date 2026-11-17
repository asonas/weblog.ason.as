# frozen_string_literal: true

require "json"

module WeblogAuthoring
  # A Ruby port of the BudouX parser (https://github.com/google/budoux), with rules added for boundaries
  # between Latin and Japanese text. budoux/ja.json is BudouX's pretrained Japanese model, unmodified.
  #
  # Copyright 2021 Google LLC
  #
  # Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in
  # compliance with the License. You may obtain a copy of the License in budoux/LICENSE or at
  # https://www.apache.org/licenses/LICENSE-2.0
  #
  # Unless required by applicable law or agreed to in writing, software distributed under the License is
  # distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  # See the License for the specific language governing permissions and limitations under the License.
  class PhraseSegmenter
    MODEL_PATH = File.expand_path("budoux/ja.json", __dir__)
    # [feature group, offset of the first character from the boundary, length]
    FEATURES = [
      ["UW1", -3, 1], ["UW2", -2, 1], ["UW3", -1, 1], ["UW4", 0, 1], ["UW5", 1, 1], ["UW6", 2, 1],
      ["BW1", -2, 2], ["BW2", -1, 2], ["BW3", 0, 2],
      ["TW1", -3, 3], ["TW2", -2, 3], ["TW3", -1, 3], ["TW4", 0, 3],
    ].freeze
    LATIN = /[\p{Latin}\p{Nd}]/
    JAPANESE = /[\p{Han}\p{Hiragana}\p{Katakana}ー]/
    CLOSING = /[、。！？）」』】]/

    def initialize(model: JSON.parse(File.read(MODEL_PATH)))
      @model = model
      @base_score = -model.each_value.sum { |group| group.each_value.sum } * 0.5
    end

    # Returns the units a line may not be broken inside. Joining them restores the text.
    def call(text)
      characters = text.chars
      return [] if characters.empty?

      units = [characters.first.dup]
      (1...characters.length).each do |index|
        if boundary?(characters, index)
          units << characters[index].dup
        else
          units.last << characters[index]
        end
      end
      units
    end

    private

    def boundary?(characters, index)
      before = characters[index - 1]
      after = characters[index]
      return true if before.match?(/\s/) && !after.match?(/\s/)
      # BudouX keeps a loanword compound such as "Webmentionクラブ" in one phrase.
      # Hiragana after a Latin word is a particle ("weblog.ason.asに"), which must not start a line.
      return true if before.match?(LATIN) && after.match?(JAPANESE) && !after.match?(/\p{Hiragana}/)
      return true if (before.match?(JAPANESE) || before.match?(CLOSING)) && after.match?(LATIN)
      return false if before.match?(LATIN) || after.match?(LATIN)

      score(characters, index).positive?
    end

    def score(characters, index)
      FEATURES.sum(@base_score) do |group, offset, length|
        start = index + offset
        next 0 if start.negative? || start + length > characters.length

        @model.fetch(group, {}).fetch(characters[start, length].join, 0)
      end
    end
  end
end
