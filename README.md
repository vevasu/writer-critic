# Writer and Critic: a multi-agent app

A standalone example app for [Eval Workbench](https://github.com/vevasu/eval-workbench): its runs show up on the Workbench's Production page.

Four agents work as a team to turn a brief into a publication-ready post, blog post or email summary.

```
Brief -> Planner -> Writer -> [ Critic -> approved? stop : Writer revises ] x up to 2 -> Editor -> Final
```

| Agent | Job | Temperature |
|---|---|---|
| Planner | Turns the brief into an outline | 0.5 |
| Writer | Writes the first draft, then revises it using the Critic's feedback | 0.9 |
| Critic | Scores the draft 1-5 on five dimensions and lists issues, as JSON | 0.2 |
| Editor | Final polish against your editing criteria | 0.2 |

The loop stops when the Critic's average score reaches `APPROVE_SCORE` (default 4.0) or after `MAX_REVISION_ROUNDS` (default 2). No agent framework and no SDK: `writer_critic/llm.py` makes plain HTTPS calls to OpenAI or Anthropic.

## Set up

```
pip install -r requirements.txt
copy .env.example .env        # then set OPENAI_API_KEY or ANTHROPIC_API_KEY in .env
```

## Run

Web app, with a live timeline of each agent's work:

```
python -m uvicorn app:app --port 8200
```

Open http://127.0.0.1:8200.

Command line:

```
python cli.py --topic "Why small code reviews beat big ones" --audience "engineering managers" ^
  --points "big reviews get rubber-stamped; small ones ship faster" --format "LinkedIn post"
```

If it won't start: run the command from the repository root (from another folder you get "Could not import module app"), and if you see "only one usage of each socket address", something is already using port 8200, so pick another with `--port 8201`.

Tests (use a scripted fake model, so no API calls): `pip install pytest`, then `python -m pytest`.

## Code map

| File | What it holds |
|---|---|
| `writer_critic/prompts.py` | One system prompt per agent, and the default editing criteria |
| `writer_critic/agents.py` | `Agent` base class and `Planner`, `Writer`, `Critic`, `Editor` |
| `writer_critic/pipeline.py` | The orchestrator: who runs next, and the critique loop |
| `writer_critic/models.py` | Data passed between agents (`Brief`, `Review`, `Step`, `Result`) |
| `writer_critic/llm.py` | The only file that talks to a provider |
| `app.py`, `static/index.html`, `cli.py` | Web and command-line front ends |

To add an agent (say a fact-checker), subclass `Agent` in `agents.py`, add its prompt to `prompts.py`, and call it from `Pipeline.run`.

## Tracing with Eval Workbench (optional)

Install the SDK from a hosted Workbench as shown on its **Get started** page (`pip install https://eval-workbench-5lofnwh6hq-uc.a.run.app/sdk/eval_workbench-0.2.0-py3-none-any.whl`), or from a checkout of [eval-workbench](https://github.com/vevasu/eval-workbench) with `pip install -e path/to/eval-workbench/sdk/python`, and set `EVAL_WORKBENCH_URL` and `EVAL_WORKBENCH_API_KEY` in `.env`. Each run is then sent to the Workbench as a trace, with one span per agent and one per model call (with token counts), under **Writer & Critic (live)** on the Production page. The format is sent as a tag and the audience and provider as metadata. It is scored by a guardrail check: the final text must not contain buzzwords such as "leverage" or "synergy". Set `APP_VERSION` in `.env` when you change a prompt, so each version is tracked separately. Without the SDK or keys, the app runs normally.

`OPENAI_BASE_URL` points the app at any OpenAI-compatible API instead of OpenAI.

## Put it online (Google Cloud Run)

The app uses one server-side model key, so everyone who can open it spends your credits. Deploy it private (the default below) and open it through `gcloud run services proxy`, or make it public only for a short demo.

It runs each job in a background thread and keeps jobs in memory, so it needs CPU between requests and a single instance: `--no-cpu-throttling --max-instances 1`.

Deploy with one command, from this folder in PowerShell (needs `gcloud`, logged in and set to the project that runs the Workbench):

```
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

`deploy.ps1` creates the `writer-critic` project and a key in the Workbench, saves that key and your OpenAI key (asked for once) in Secret Manager, lets Cloud Run read them, and deploys. It is safe to run again: each step skips what already exists, and it replaces a saved Workbench key that no longer works. Deploy a new version with `-Version v2`.

When it finishes, open the app with `gcloud run services proxy writer-critic --region us-central1 --port 8200` and go to http://127.0.0.1:8200.

To see its traffic, open the Workbench, choose **I have a key**, paste the app's key (`gcloud secrets versions access latest --secret=writer-critic-workbench-key`) and open **Production**. After changing a prompt or model, run `deploy.ps1 -Version v2` and the Production page compares the two versions. `.gcloudignore` keeps your local `.env` out of the upload.
