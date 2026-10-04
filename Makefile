# Convenience targets.
.DEFAULT_GOAL := help
PSP_URL   ?= http://localhost:4242
BASE_URL  ?= http://localhost:3000
HOLD_TTL  ?= 6

help: ## show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | column -t -s "$$(printf '\t')"

psp: ## run the fake payment provider
	WEBHOOK_URL=$(BASE_URL)/api/webhooks/stripe python3 spec/fake-psp/server.py

reference: ## run the in-memory reference implementation
	HOLD_TTL_SECONDS=$(HOLD_TTL) python3 spec/reference/app.py

conformance: ## run the conformance suite against BASE_URL
	cd spec/conformance && HOLD_TTL_SECONDS=$(HOLD_TTL) \
		python3 run.py --base-url $(BASE_URL) --psp-url $(PSP_URL)

mutation-test: ## break the reference app 21 ways, assert the suite catches each
	python3 spec/conformance/mutation_test.py

ruby-setup: ## install gems, then create + migrate + seed the Rails databases
	cd apps/ruby && bundle install && bin/rails db:prepare && bin/rails db:seed

ruby-test: ## run the Rails unit + integration tests (no PSP or worker needed)
	cd apps/ruby && bin/rails test

ruby-server: ## run the Rails app on :3000
	cd apps/ruby && HOLD_TTL_SECONDS=$(HOLD_TTL) bin/rails server -p 3000

ruby-jobs: ## run the Solid Queue worker
	cd apps/ruby && HOLD_TTL_SECONDS=$(HOLD_TTL) bin/jobs

ruby-conformance: ruby-reseed conformance ## reseed, then run the suite against Rails

ruby-reseed: ## reset seed data between conformance runs
	@cd apps/ruby && bin/rails db:seed

cases: ## list the conformance catalogue
	@cd spec/conformance && python3 run.py --list

verify-spec: ## parse openapi.yaml and check every $$ref resolves
	@ruby -ryaml -e 'd=YAML.load_file("spec/openapi.yaml"); \
	  refs=[]; w=->(n){ case n when Hash then n.each{|k,v| refs<<v if k=="$$ref"; w.(v)} \
	  when Array then n.each{|v| w.(v)} end }; w.(d); \
	  bad=refs.uniq.reject{|r| d.dig(*r[2..].split("/"))}; \
	  abort("BROKEN: #{bad}") unless bad.empty?; \
	  puts "openapi #{d["openapi"]}: #{d["paths"].size} paths, \
#{d["components"]["schemas"].size} schemas, #{refs.uniq.size} refs OK"'

.PHONY: help psp reference conformance mutation-test cases verify-spec \
	ruby-setup ruby-test ruby-server ruby-jobs ruby-conformance ruby-reseed

# The book's own targets. book.mk stays with the book's source and is not part of
# the public code repository, where this include finds nothing and does nothing.
-include book.mk
