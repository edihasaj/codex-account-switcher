import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const workflowPath = new URL("../.github/workflows/ci.yml", import.meta.url);
const pullRequestTypes = ["opened", "synchronize", "reopened", "edited"];
const nativeContexts = [
  ["main push", { name: "push", ref: "refs/heads/main" }, false],
  ["production push", { name: "push", ref: "refs/heads/production" }, false],
  ["tag push", { name: "push", ref: "refs/tags/v1.2.3" }, false],
  ["main pull request", { name: "pull_request", baseRef: "main" }, false],
  ["production PR opened", { name: "pull_request", baseRef: "production", action: "opened" }, false],
  ["production PR edited", { name: "pull_request", baseRef: "production", action: "edited" }, false],
  ["manual native opt-in", { name: "workflow_dispatch", ref: "refs/heads/production", runNative: true }, true],
  ["manual main opt-in", { name: "workflow_dispatch", ref: "refs/heads/main", runNative: true }, false],
  ["manual native opt-out on production", { name: "workflow_dispatch", ref: "refs/heads/production", runNative: false }, false],
  ["manual native input missing on production", { name: "workflow_dispatch", ref: "refs/heads/production" }, false],
  ["schedule on production", { name: "schedule", ref: "refs/heads/production" }, false],
];

function loadWorkflow(path) {
  const ruby = `
    require "yaml"
    require "json"
    def normalize(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), output|
          output[key == true ? "on" : key.to_s] = normalize(child)
        end
      when Array then value.map { |child| normalize(child) }
      else value
      end
    end
    puts JSON.generate(normalize(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)))
  `;
  return JSON.parse(
    execFileSync("ruby", ["-ryaml", "-rjson", "-e", ruby, fileURLToPath(path)], {
      encoding: "utf8",
    }),
  );
}

function isMacosOrXcode(value) {
  if (typeof value === "string") return /macos|xcode/i.test(value);
  if (Array.isArray(value)) return value.some(isMacosOrXcode);
  return false;
}

function evaluateGithubExpression(expression, context) {
  const body = expression.replace(/^\s*\$\{\{\s*|\s*\}\}\s*$/g, "");
  assert.match(body, /^[\s!()&|=.'_a-zA-Z0-9/:-]+$/, `unsupported native guard: ${expression}`);
  const values = {
    "github.event_name": context.name,
    "github.base_ref": context.baseRef ?? "",
    "github.ref_name": context.ref?.replace(/^refs\/heads\//, "") ?? "",
    "github.ref": context.ref ?? "",
    "inputs.run_native": context.runNative,
  };
  const javascript = body
    .replaceAll("!cancelled()", "true")
    .replace(
      /github\.event_name|github\.base_ref|github\.ref_name|github\.ref|inputs\.run_native/g,
      (reference) => JSON.stringify(values[reference]),
    );
  return Function(`"use strict"; return Boolean(${javascript});`)();
}

function pullRequestTriggers(filter, context) {
  return filter.branches.includes(context.baseRef) && filter.types.includes(context.action);
}

function assertNativePolicy(workflow) {
  assert.deepEqual(Object.keys(workflow.on).sort(), ["pull_request", "push", "workflow_dispatch"]);
  assert.deepEqual(workflow.on.push, { branches: ["production"] });
  assert.deepEqual(workflow.on.pull_request, {
    branches: ["production"],
    types: pullRequestTypes,
  });
  assert.ok(workflow.on.pull_request.types.includes("edited"));
  assert.equal(
    pullRequestTriggers(workflow.on.pull_request, { baseRef: "production", action: "edited" }),
    true,
  );
  assert.equal(
    pullRequestTriggers(workflow.on.pull_request, { baseRef: "production", action: "closed" }),
    false,
  );
  assert.deepEqual(workflow.on.workflow_dispatch.inputs.run_native, {
    description: "Run paid macOS validation",
    required: false,
    type: "boolean",
    default: false,
  });

  const nativeJobs = Object.entries(workflow.jobs)
    .filter(([, job]) => isMacosOrXcode(job["runs-on"]))
    .map(([jobId]) => jobId)
    .sort();
  assert.deepEqual(nativeJobs, ["validate"]);

  const guard = workflow.jobs.validate.if;
  assert.equal(typeof guard, "string", "validate must have a job-level native guard");
  assert.doesNotMatch(guard, /github\.event\.inputs/);
  assert.match(guard, /inputs\.run_native\s*==\s*true/);
  for (const [name, context, expected] of nativeContexts) {
    assert.equal(evaluateGithubExpression(guard, context), expected, name);
  }
}

test("actual workflow YAML admits hosted macOS only through the native policy", () => {
  assertNativePolicy(loadWorkflow(workflowPath));
});

test("policy checker rejects common hosted-macOS routing regressions", () => {
  const workflow = loadWorkflow(workflowPath);
  const mutations = [
    (definition) => {
      definition.on.schedule = [{ cron: "0 0 * * *" }];
    },
    (definition) => {
      definition.on.workflow_dispatch.inputs.run_native.type = "string";
    },
    (definition) => {
      definition.jobs.unconditional_macos = { "runs-on": "macos-14" };
    },
    (definition) => {
      delete definition.on.workflow_dispatch;
    },
    (definition) => {
      definition.on.pull_request.branches = ["main"];
    },
    (definition) => {
      definition.on.pull_request.types = ["opened", "synchronize", "reopened"];
    },
    (definition) => {
      definition.jobs.validate.if = "${{ github.ref_name == 'production' }}";
    },
  ];

  for (const mutate of mutations) {
    const mutated = structuredClone(workflow);
    mutate(mutated);
    assert.throws(() => assertNativePolicy(mutated));
  }
});
