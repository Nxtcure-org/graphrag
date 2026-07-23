testcli:
	uv run python -m graphrag query --root nccn_graphrag --method local "After a testicular cancer patient gets a brain MRI/scan, what should be done? When is brain imaging indicated, and if brain metastases are found, how are they managed?"

runapi:
	uv run --with klein python api/app.py

testapi:
	curl -s -X POST localhost:8899/query -H 'content-type: application/json' -d '{"query":"What to do after a brain scan?","method":"local"}' | jq

runui:
	 NCCN_API=http://127.0.0.1:8899 elixir nccn_ui/nccn_ui.exs
