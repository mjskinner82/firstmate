#!/usr/bin/env node
// Durable dual-principal authorization and task lifecycle implementation.

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MODULE_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIR = dirname(MODULE_PATH);
const ROOT = resolve(SCRIPT_DIR, "..");
const HOME = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || ROOT;
const DATA = process.env.FM_DATA_OVERRIDE || join(HOME, "data");
const STATE = process.env.FM_STATE_OVERRIDE || join(HOME, "state");
const CONFIG_PATH =
  process.env.FM_PRINCIPAL_CONFIG || join(HOME, "config", "principal-authority.json");
const STORE = join(DATA, "principal-authority");
const TASKS = join(STORE, "tasks");
const RECEIPTS = join(STORE, "receipts");
const DEFAULT_EVENTS = join(STATE, "hermes-ingress.events.jsonl");

const CONFIG_SCHEMA = "fm-principal-authority-config.v1";
const TASK_SCHEMA = "fm-principal-task.v2";
const RECEIPT_SCHEMA = "fm-principal-receipt.v1";
const STATUS_SCHEMA = "fm-principal-status.v1";
const PRIORITIES = new Set(["low", "normal", "high", "urgent"]);
const LIFECYCLE_STATES = [
  "queued",
  "delivered",
  "accepted",
  "running",
  "blocked",
  "failed",
  "cancelled",
  "completed",
];
const PROGRESS_STATES = new Set(LIFECYCLE_STATES.filter((state) => state !== "blocked"));
const TERMINAL_STATES = new Set(["failed", "cancelled", "completed"]);
const HIGHER_BOUNDARIES = new Set([
  "financial-transaction",
  "outward-facing-creation",
  "private-data-migration",
  "destructive",
  "irreversible",
  "security-sensitive",
  "remote-access",
  "identity-change",
  "secret-disclosure",
  "pr-merge",
]);
const MERCURY_EVENT_KEYS = new Set([
  "acceptance_criteria",
  "assignment_payload_hash",
  "authenticated_caller",
  "created_at",
  "event_id",
  "event_type",
  "idempotency_key",
  "identity_key_id",
  "objective",
  "priority",
  "repository_ref",
  "source_channel",
  "source_conversation_ref",
  "source_message_ref",
  "task_id",
]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_RE = /^[0-9a-f]{64}$/;
let runtimeHooks = Object.freeze({});

class AuthorityError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function fail(code, message) {
  throw new AuthorityError(code, message);
}

function ensureDirectories() {
  for (const path of [DATA, STORE, TASKS, RECEIPTS]) {
    mkdirSync(path, { recursive: true, mode: 0o700 });
    chmodSync(path, 0o700);
  }
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value && typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) result[key] = stableValue(value[key]);
    return result;
  }
  return value;
}

function asciiJson(value, pretty = false) {
  return JSON.stringify(stableValue(value), null, pretty ? 2 : 0).replace(
    /[^\x00-\x7f]/g,
    (character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`,
  );
}

function hashValue(value) {
  return createHash("sha256").update(asciiJson(value)).digest("hex");
}

function now() {
  const value = process.env.FM_PRINCIPAL_NOW || new Date().toISOString();
  if (!Number.isFinite(Date.parse(value))) fail("invalid_time", "FM_PRINCIPAL_NOW is not an ISO timestamp");
  return new Date(value).toISOString();
}

function atomicWriteJson(path, value) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temp = join(dirname(path), `.${process.pid}.${randomUUID()}.tmp`);
  try {
    writeFileSync(temp, `${asciiJson(value, true)}\n`, { encoding: "utf8", mode: 0o600, flag: "wx" });
    chmodSync(temp, 0o600);
    renameSync(temp, path);
    chmodSync(path, 0o600);
  } finally {
    if (existsSync(temp)) unlinkSync(temp);
  }
}

function readJson(path, label = path) {
  let value;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail("invalid_json", `${label} is not valid JSON: ${error.message}`);
  }
  return value;
}

function requireSecureRegularFile(path, label) {
  let info;
  try {
    info = lstatSync(path);
  } catch (error) {
    fail("missing_file", `${label} is unavailable: ${error.message}`);
  }
  if (!info.isFile() || info.isSymbolicLink()) fail("unsafe_file", `${label} must be a regular non-symlink file`);
  if ((info.mode & 0o077) !== 0) fail("unsafe_file", `${label} must not grant group or world permissions`);
  if (typeof process.getuid === "function" && info.uid !== process.getuid()) {
    fail("unsafe_file", `${label} is not owned by the current user`);
  }
}

function exactKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail("schema_drift", `${label} must be an object`);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail("schema_drift", `${label} keys drifted: expected ${wanted.join(",")}; got ${actual.join(",")}`);
  }
}

function boundedText(value, name, maximum, { allowNewlines = true } = {}) {
  if (typeof value !== "string" || !value.trim()) fail("invalid_input", `${name} must be non-empty text`);
  const text = value.trim();
  if (text.length > maximum) fail("invalid_input", `${name} exceeds ${maximum} characters`);
  const invalid = [...text].some((character) => {
    const code = character.charCodeAt(0);
    return code < 32 && (!allowNewlines || !"\n\t".includes(character));
  });
  if (invalid) fail("invalid_input", `${name} contains a forbidden control character`);
  return text;
}

function boundedList(value, name, maximumItems, maximumLength) {
  if (!Array.isArray(value) || value.length < 1 || value.length > maximumItems) {
    fail("invalid_input", `${name} must contain 1 to ${maximumItems} items`);
  }
  return value.map((item, index) => boundedText(item, `${name}[${index}]`, maximumLength));
}

function parseJsonArray(value, name, { allowEmpty = true } = {}) {
  let parsed;
  try {
    parsed = JSON.parse(value || "[]");
  } catch (error) {
    fail("invalid_input", `${name} is not valid JSON: ${error.message}`);
  }
  if (!Array.isArray(parsed) || (!allowEmpty && parsed.length === 0) || parsed.length > 20) {
    fail("invalid_input", `${name} must be an array of at most 20 items`);
  }
  return parsed;
}

function normalizeEvidence(rows, name, required) {
  if (!Array.isArray(rows) || rows.length > 20) fail("invalid_input", `${name} must be an array of at most 20 items`);
  return rows.map((row, index) => {
    exactKeys(row, new Set(required), `${name}[${index}]`);
    const result = {};
    for (const key of required) result[key] = boundedText(row[key], `${name}[${index}].${key}`, 1500);
    return result;
  });
}

function normalizeObjective(value) {
  return boundedText(value, "objective", 12000).normalize("NFKC").replace(/\s+/g, " ");
}

function objectiveHash(objective) {
  return createHash("sha256").update(normalizeObjective(objective)).digest("hex");
}

function parseArguments(argv) {
  if (argv.length === 0 || argv[0] === "--help" || argv[0] === "-h") return { command: "help", flags: {} };
  const command = argv[0];
  const flags = {};
  for (let index = 1; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) fail("usage", `unexpected positional argument: ${token}`);
    const equal = token.indexOf("=");
    let name;
    let value;
    if (equal >= 0) {
      name = token.slice(2, equal);
      value = token.slice(equal + 1);
    } else {
      name = token.slice(2);
      if (["pending", "refusals"].includes(name)) value = true;
      else {
        index += 1;
        if (index >= argv.length) fail("usage", `--${name} requires a value`);
        value = argv[index];
      }
    }
    if (Object.hasOwn(flags, name)) fail("usage", `--${name} was provided more than once`);
    flags[name] = value;
  }
  return { command, flags };
}

function requireFlag(flags, name, maximum = 1000) {
  if (!Object.hasOwn(flags, name) || flags[name] === true) fail("usage", `--${name} is required`);
  return boundedText(flags[name], `--${name}`, maximum);
}

function rejectUnknownFlags(flags, allowed) {
  for (const name of Object.keys(flags)) if (!allowed.has(name)) fail("usage", `unknown flag: --${name}`);
}

function parseBoundaries(value, { allowNone = false } = {}) {
  const text = boundedText(value, "boundaries", 500, { allowNewlines: false });
  if (text === "none" && allowNone) return [];
  const values = [...new Set(text.split(",").map((item) => item.trim()).filter(Boolean))].sort();
  if (values.length === 0) fail("invalid_input", "at least one higher boundary is required");
  for (const boundary of values) {
    if (!HIGHER_BOUNDARIES.has(boundary)) fail("invalid_input", `unknown higher boundary: ${boundary}`);
  }
  return values;
}

function readConfig() {
  requireSecureRegularFile(CONFIG_PATH, "principal authority config");
  const config = readJson(CONFIG_PATH, "principal authority config");
  exactKeys(config, new Set(["schema", "captain_sources", "mercury_sources"]), "principal authority config");
  if (config.schema !== CONFIG_SCHEMA) fail("schema_drift", `principal authority config schema must be ${CONFIG_SCHEMA}`);
  if (!Array.isArray(config.captain_sources) || config.captain_sources.length !== 1) {
    fail("invalid_config", "captain_sources must contain exactly one descriptive trusted-session principal");
  }
  if (!Array.isArray(config.mercury_sources) || config.mercury_sources.length < 1 || config.mercury_sources.length > 20) {
    fail("invalid_config", "mercury_sources must contain 1 to 20 entries");
  }
  config.captain_sources = config.captain_sources.map((source, index) => {
    exactKeys(source, new Set(["identity", "channel"]), `captain_sources[${index}]`);
    return {
      identity: boundedText(source.identity, `captain_sources[${index}].identity`, 200),
      channel: boundedText(source.channel, `captain_sources[${index}].channel`, 200),
    };
  });
  config.mercury_sources = config.mercury_sources.map((source, index) => {
    exactKeys(source, new Set(["identity", "key_id"]), `mercury_sources[${index}]`);
    return {
      identity: boundedText(source.identity, `mercury_sources[${index}].identity`, 200),
      key_id: boundedText(source.key_id, `mercury_sources[${index}].key_id`, 200),
    };
  });
  return config;
}

function validateMercurySource(config, identity, keyId) {
  const match = config.mercury_sources.some((source) => source.identity === identity && source.key_id === keyId);
  if (!match) fail("mercury_identity_rejected", "Mercury caller and identity key id are not allowlisted together");
}

function receiptPath(id) {
  return join(RECEIPTS, `${id}.json`);
}

function taskPath(taskId) {
  return join(TASKS, `${taskId}.json`);
}

function verifyReceipt(receipt, path = "receipt") {
  if (!receipt || receipt.schema !== RECEIPT_SCHEMA || !SHA256_RE.test(receipt.receipt_id || "")) {
    fail("receipt_drift", `${path} has an invalid receipt schema or id`);
  }
  const base = structuredClone(receipt);
  delete base.receipt_id;
  const expected = hashValue(base);
  if (expected !== receipt.receipt_id) fail("receipt_drift", `${path} content hash does not match its immutable receipt id`);
  return receipt;
}

function listReceipts() {
  ensureDirectories();
  return readdirSync(RECEIPTS)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => {
      const receipt = verifyReceipt(readJson(join(RECEIPTS, name)), `receipt ${name}`);
      if (name !== `${receipt.receipt_id}.json`) fail("receipt_drift", `receipt filename does not match its content hash: ${name}`);
      return receipt;
    });
}

function listTaskFiles() {
  ensureDirectories();
  return readdirSync(TASKS).filter((name) => name.endsWith(".json")).sort();
}

function writeReceipt(base) {
  const existing = listReceipts().find((receipt) => receipt.idempotency_key === base.idempotency_key);
  if (existing) {
    const existingBase = structuredClone(existing);
    delete existingBase.receipt_id;
    if (hashValue(existingBase) !== hashValue(base)) {
      fail("idempotency_conflict", `receipt idempotency key was reused with different content: ${base.idempotency_key}`);
    }
    return existing;
  }
  const receipt = { ...base, receipt_id: hashValue(base) };
  const path = receiptPath(receipt.receipt_id);
  if (existsSync(path)) {
    const current = verifyReceipt(readJson(path), path);
    if (asciiJson(current) !== asciiJson(receipt)) fail("receipt_collision", `receipt hash collision at ${path}`);
  } else {
    atomicWriteJson(path, receipt);
    chmodSync(path, 0o400);
  }
  return receipt;
}

function receiptForKey(idempotencyKey, receipts = null) {
  const rows = receipts || listReceipts();
  return rows.find((receipt) => receipt.idempotency_key === idempotencyKey) || null;
}

function replayForCommand(idempotencyKey, receipts, taskId, operation) {
  const receipt = receiptForKey(idempotencyKey, receipts);
  if (!receipt) return null;
  if (receipt.task_id !== taskId || receipt.operation_hash !== hashValue(operation)) {
    fail("idempotency_conflict", `command idempotency key was reused for another operation: ${idempotencyKey}`);
  }
  return receipt;
}

function recoverStore({ repair }) {
  ensureDirectories();
  const receipts = listReceipts();
  const byTask = new Map();
  for (const receipt of receipts) {
    if (!receipt.task_after) continue;
    const task = receipt.task_after;
    if (!task || task.schema !== TASK_SCHEMA || !UUID_RE.test(task.task_id || "")) {
      fail("task_drift", `receipt ${receipt.receipt_id} embeds an invalid task view`);
    }
    if (task.task_id !== receipt.task_id || task.revision !== receipt.revision) {
      fail("task_drift", `receipt ${receipt.receipt_id} task identity or revision drifted`);
    }
    if (!byTask.has(task.task_id)) byTask.set(task.task_id, []);
    byTask.get(task.task_id).push(receipt);
  }
  const materialized = new Map();
  const objectives = new Map();
  for (const [taskId, rows] of byTask) {
    rows.sort((left, right) => left.revision - right.revision || left.receipt_id.localeCompare(right.receipt_id));
    for (let index = 0; index < rows.length; index += 1) {
      if (rows[index].revision !== index + 1) fail("task_drift", `task ${taskId} receipt revisions are not contiguous from 1`);
      if (index > 0 && rows[index].from_state !== rows[index - 1].to_state) {
        fail("task_drift", `task ${taskId} receipt state chain diverged at revision ${rows[index].revision}`);
      }
    }
    const expected = rows.at(-1).task_after;
    validateTask(expected);
    const previous = objectives.get(expected.objective_hash);
    if (previous && previous !== taskId) fail("duplicate_objective", `objective hash maps to both ${previous} and ${taskId}`);
    objectives.set(expected.objective_hash, taskId);
    const path = taskPath(taskId);
    if (!existsSync(path) || asciiJson(readJson(path)) !== asciiJson(expected)) {
      if (!repair) fail("task_view_drift", `task ${taskId} does not match its immutable receipt ledger`);
      atomicWriteJson(path, expected);
    }
    materialized.set(taskId, expected);
  }
  for (const name of listTaskFiles()) {
    const taskId = name.slice(0, -5);
    if (!materialized.has(taskId)) fail("task_view_drift", `task view ${name} has no immutable receipt history`);
  }
  const idempotency = new Map();
  for (const receipt of receipts) {
    const previous = idempotency.get(receipt.idempotency_key);
    if (previous && previous !== receipt.receipt_id) fail("idempotency_conflict", `duplicate receipt idempotency key: ${receipt.idempotency_key}`);
    idempotency.set(receipt.idempotency_key, receipt.receipt_id);
  }
  return { receipts, tasks: materialized };
}

function constraintKey(constraint) {
  if (constraint.kind === "captain-pause") return "captain-pause";
  if (constraint.kind === "captain-approval") return `captain-approval:${constraint.boundaries[0]}`;
  return `operational:${hashValue({ reason: constraint.reason, recorded_at: constraint.recorded_at })}`;
}

function normalizeConstraints(constraints) {
  if (!Array.isArray(constraints) || constraints.length > 32) {
    fail("task_drift", "task constraints must be an array of at most 32 members");
  }
  const normalized = constraints.map((constraint, index) => {
    if (!constraint || typeof constraint !== "object" || Array.isArray(constraint)) {
      fail("task_drift", `task constraint ${index} must be an object`);
    }
    if (constraint.kind === "captain-pause") {
      exactKeys(constraint, new Set(["kind", "reason", "boundaries", "recorded_at", "instruction_id"]), `task constraint ${index}`);
      boundedText(constraint.instruction_id, `task constraint ${index}.instruction_id`, 300);
      if (!Array.isArray(constraint.boundaries) || constraint.boundaries.length !== 0) {
        fail("task_drift", "captain-pause constraint must not carry authority boundaries");
      }
    } else if (constraint.kind === "captain-approval") {
      exactKeys(constraint, new Set(["kind", "reason", "boundaries", "recorded_at"]), `task constraint ${index}`);
      if (!Array.isArray(constraint.boundaries) || constraint.boundaries.length !== 1 || !HIGHER_BOUNDARIES.has(constraint.boundaries[0])) {
        fail("task_drift", "captain-approval constraint must carry exactly one known higher boundary");
      }
    } else if (constraint.kind === "operational") {
      exactKeys(constraint, new Set(["kind", "reason", "boundaries", "recorded_at"]), `task constraint ${index}`);
      if (!Array.isArray(constraint.boundaries) || constraint.boundaries.length !== 0) {
        fail("task_drift", "operational constraint must not carry authority boundaries");
      }
    } else {
      fail("task_drift", `unknown task constraint kind: ${constraint.kind}`);
    }
    boundedText(constraint.reason, `task constraint ${index}.reason`, 12000);
    if (!Number.isFinite(Date.parse(constraint.recorded_at))) {
      fail("task_drift", `task constraint ${index}.recorded_at must be an ISO timestamp`);
    }
    return structuredClone(constraint);
  });
  const keys = normalized.map(constraintKey);
  if (new Set(keys).size !== keys.length) fail("task_drift", "task constraint set contains a duplicate member");
  return normalized.sort((left, right) => constraintKey(left).localeCompare(constraintKey(right)));
}

function addConstraints(current, additions) {
  const constraints = new Map(normalizeConstraints(current).map((constraint) => [constraintKey(constraint), constraint]));
  for (const constraint of normalizeConstraints(additions)) constraints.set(constraintKey(constraint), constraint);
  return normalizeConstraints([...constraints.values()]);
}

function removeConstraints(current, predicate) {
  return normalizeConstraints(normalizeConstraints(current).filter((constraint) => !predicate(constraint)));
}

function requiredBoundaries(constraints) {
  return normalizeConstraints(constraints)
    .filter((constraint) => constraint.kind === "captain-approval")
    .map((constraint) => constraint.boundaries[0])
    .sort();
}

function deriveLifecycleState(progressState, constraints) {
  if (!PROGRESS_STATES.has(progressState)) fail("task_drift", `invalid task progress state: ${progressState}`);
  return normalizeConstraints(constraints).length > 0 ? "blocked" : progressState;
}

function withDerivedTaskFields(task) {
  const blockers = normalizeConstraints(task.blockers);
  return {
    ...task,
    state: deriveLifecycleState(task.progress_state, blockers),
    blockers,
    authority: {
      ...task.authority,
      captain_required_boundaries: requiredBoundaries(blockers),
    },
  };
}

function validateTask(task) {
  if (task.schema !== TASK_SCHEMA || !UUID_RE.test(task.task_id || "") || !Number.isInteger(task.revision) || task.revision < 1) {
    fail("task_drift", "task has invalid schema, id, or revision");
  }
  if (!PROGRESS_STATES.has(task.progress_state)) fail("task_drift", `task ${task.task_id} has an invalid progress state`);
  if (!LIFECYCLE_STATES.includes(task.state)) fail("task_drift", `task ${task.task_id} has an invalid lifecycle state`);
  if (task.objective_hash !== objectiveHash(task.objective)) fail("task_drift", `task ${task.task_id} objective fingerprint drifted`);
  if (!Array.isArray(task.acceptance_criteria) || !Array.isArray(task.blockers) || !Array.isArray(task.artifacts) || !Array.isArray(task.verification)) {
    fail("task_drift", `task ${task.task_id} has invalid bounded arrays`);
  }
  const normalized = normalizeConstraints(task.blockers);
  if (asciiJson(task.blockers) !== asciiJson(normalized)) fail("task_drift", `task ${task.task_id} constraints are not canonical`);
  const derivedState = deriveLifecycleState(task.progress_state, normalized);
  if (task.state !== derivedState) fail("task_drift", `task ${task.task_id} lifecycle state does not match its constraint set`);
  const boundaries = requiredBoundaries(normalized);
  if (asciiJson(task.authority?.captain_required_boundaries) !== asciiJson(boundaries)) {
    fail("task_drift", `task ${task.task_id} higher-boundary projection does not match its constraint set`);
  }
  if (!task.lifecycle_timestamps || task.lifecycle_timestamps[`${task.state}_at`] === null) {
    fail("task_drift", `task ${task.task_id} current state lacks an explicit timestamp`);
  }
  if (task.lifecycle_timestamps[`${task.progress_state}_at`] === null) {
    fail("task_drift", `task ${task.task_id} progress state lacks an explicit timestamp`);
  }
  if (["running", "failed", "completed"].includes(task.progress_state) && !task.lifecycle_timestamps.accepted_at) {
    fail("acceptance_inferred", `task ${task.task_id} reached ${task.progress_state} progress without explicit acceptance`);
  }
  if (task.lifecycle_timestamps.accepted_at && !task.authority?.basis) {
    fail("acceptance_inferred", `task ${task.task_id} has accepted_at without an authority basis`);
  }
  if (task.lifecycle_timestamps.accepted_at && !task.owner) {
    fail("task_drift", `task ${task.task_id} has explicit acceptance without an execution owner`);
  }
  if (TERMINAL_STATES.has(task.progress_state) && normalized.length > 0) {
    fail("task_drift", `terminal task ${task.task_id} retains active constraints`);
  }
}

function applyReceipt(base) {
  const receipt = writeReceipt(base);
  if (receipt.task_after) atomicWriteJson(taskPath(receipt.task_after.task_id), receipt.task_after);
  return receipt;
}

function transitionReceipt(task, options) {
  const timestamp = options.recordedAt || now();
  let next = structuredClone(task);
  next.revision += 1;
  next.progress_state = options.progressState || (options.to === "blocked" ? task.progress_state : options.to);
  next.lifecycle_timestamps.updated_at = timestamp;
  options.mutate?.(next, timestamp);
  next = withDerivedTaskFields(next);
  const progressTimestampKey = `${next.progress_state}_at`;
  if (next.lifecycle_timestamps[progressTimestampKey] === null) next.lifecycle_timestamps[progressTimestampKey] = timestamp;
  const stateTimestampKey = `${next.state}_at`;
  if (next.lifecycle_timestamps[stateTimestampKey] === null) next.lifecycle_timestamps[stateTimestampKey] = timestamp;
  validateTask(next);
  return applyReceipt({
    schema: RECEIPT_SCHEMA,
    receipt_type: options.receiptType || "lifecycle-transition",
    idempotency_key: options.idempotencyKey,
    task_id: task.task_id,
    objective_hash: task.objective_hash,
    revision: next.revision,
    from_state: task.state,
    to_state: next.state,
    source: options.source,
    reason: options.reason,
    authority: options.authority || null,
    supersedes_instruction_id: options.supersedesInstructionId || null,
    notification_class: options.notificationClass || "silent",
    operation_hash: options.operationHash || null,
    recorded_at: timestamp,
    task_after: next,
  });
}

function initialTimestamps() {
  const result = { updated_at: null };
  for (const state of LIFECYCLE_STATES) result[`${state}_at`] = null;
  return result;
}

function assignmentPayload(event) {
  return {
    acceptance_criteria: event.acceptance_criteria,
    caller_identity: event.authenticated_caller,
    created_at: event.created_at,
    event_id: event.event_id,
    event_type: event.event_type,
    idempotency_key: event.idempotency_key,
    identity_key_id: event.identity_key_id,
    objective: event.objective,
    priority: event.priority,
    repository_ref: event.repository_ref,
    source_channel: event.source_channel,
    source_conversation_ref: event.source_conversation_ref,
    source_message_ref: event.source_message_ref,
    task_id: event.task_id,
  };
}

function validateMercuryEvent(config, event, lineNumber) {
  exactKeys(event, MERCURY_EVENT_KEYS, `Mercury event line ${lineNumber}`);
  if (!SHA256_RE.test(event.event_id || "")) fail("schema_drift", `Mercury event line ${lineNumber} has an invalid event_id`);
  if (!UUID_RE.test(event.task_id || "")) fail("schema_drift", `Mercury event line ${lineNumber} has an invalid task_id`);
  validateMercurySource(config, event.authenticated_caller, event.identity_key_id);
  boundedText(event.idempotency_key, "idempotency_key", 200, { allowNewlines: false });
  boundedText(event.objective, "objective", 12000);
  boundedList(event.acceptance_criteria, "acceptance_criteria", 20, 1000);
  boundedText(event.repository_ref, "repository_ref", 500, { allowNewlines: false });
  if (!PRIORITIES.has(event.priority)) fail("invalid_input", "priority must be low, normal, high, or urgent");
  boundedText(event.source_channel, "source_channel", 200, { allowNewlines: false });
  boundedText(event.source_conversation_ref, "source_conversation_ref", 500, { allowNewlines: false });
  boundedText(event.source_message_ref, "source_message_ref", 500, { allowNewlines: false });
  if (!Number.isFinite(Date.parse(event.created_at))) fail("schema_drift", "created_at must be an ISO timestamp");
  const payloadHash = hashValue(assignmentPayload(event));
  if (!SHA256_RE.test(event.assignment_payload_hash || "") || payloadHash !== event.assignment_payload_hash) {
    fail("mercury_identity_rejected", "Mercury assignment payload integrity check failed");
  }
  return payloadHash;
}

function sourceFromMercury(event) {
  return {
    principal: "mercury",
    identity: event.authenticated_caller,
    identity_key_id: event.identity_key_id,
    identity_verified: true,
    verification: "upstream-hmac-and-local-payload-hash",
    channel: event.source_channel,
    conversation: event.source_conversation_ref,
    message: event.source_message_ref,
    event_id: event.event_id,
    assignment_payload_hash: event.assignment_payload_hash,
  };
}

function makeBaseTask(event, source) {
  const task = {
    schema: TASK_SCHEMA,
    task_id: event.task_id,
    revision: 0,
    idempotency_key: event.idempotency_key,
    objective_hash: objectiveHash(event.objective),
    source_identity: {
      principal: source.principal,
      identity: source.identity,
      identity_key_id: source.identity_key_id || null,
      identity_verified: true,
      verification: source.verification,
    },
    source_conversation: {
      channel: source.channel,
      conversation: source.conversation,
      message: source.message,
    },
    objective: boundedText(event.objective, "objective", 12000),
    acceptance_criteria: boundedList(event.acceptance_criteria, "acceptance_criteria", 20, 1000),
    repository: boundedText(event.repository_ref, "repository_ref", 500, { allowNewlines: false }),
    priority: event.priority,
    progress_state: "queued",
    lifecycle_timestamps: initialTimestamps(),
    owner: null,
    blockers: [],
    artifacts: [],
    verification: [],
    terminal_result: null,
    authority: {
      basis: null,
      assessed_by: null,
      assessment: null,
      captain_required_boundaries: [],
      captain_authorized_boundaries: [],
    },
    effective_instruction: {
      instruction_id: source.event_id || source.instruction_id,
      principal: source.principal,
      action: "submit",
      direction: boundedText(event.objective, "objective", 12000),
      source_channel: source.channel,
      source_conversation: source.conversation,
    },
  };
  return withDerivedTaskFields(task);
}

function findTaskByObjective(tasks, hash) {
  return [...tasks.values()].find((task) => task.objective_hash === hash) || null;
}

function recordRefusal({ idempotencyKey, event, reasonCode, reason, payloadHash }) {
  const existing = listReceipts().find((receipt) => receipt.idempotency_key === idempotencyKey);
  if (existing) return { receipt: existing, isNew: false };
  const receipt = writeReceipt({
    schema: RECEIPT_SCHEMA,
    receipt_type: "refusal",
    idempotency_key: idempotencyKey,
    task_id: null,
    objective_hash: null,
    revision: null,
    from_state: null,
    to_state: null,
    source: {
      principal_claim: event?.authenticated_caller || event?.caller_identity || (event?.captain_text ? "captain" : "unknown"),
      identity_key_id: event?.identity_key_id || event?.caller_key_id || null,
      channel: event?.source_channel || null,
      conversation: event?.source_conversation_ref || null,
      message: event?.source_message_ref || null,
      event_id: event?.event_id || null,
      payload_hash: payloadHash,
    },
    reason_code: reasonCode,
    reason,
    authority: null,
    supersedes_instruction_id: null,
    notification_class: "silent",
    recorded_at: now(),
    task_after: null,
  });
  return { receipt, isNew: true };
}

function ingestMercury(event, store) {
  const source = sourceFromMercury(event);
  const hash = objectiveHash(event.objective);
  const eventReceipts = store.receipts.filter((receipt) => receipt.source?.event_id === event.event_id);
  if (eventReceipts.some((receipt) => receipt.source?.assignment_payload_hash !== event.assignment_payload_hash)) {
    fail("replay_rejected", `event ${event.event_id} was replayed with different payload integrity`);
  }
  const completedEventReceipt = eventReceipts.find(
    (receipt) => receipt.receipt_type === "duplicate-objective-refused" || receipt.to_state === "delivered",
  );
  if (completedEventReceipt) {
    return { kind: "replay", task: completedEventReceipt.task_id ? store.tasks.get(completedEventReceipt.task_id) : null };
  }
  const idempotencyReceipts = store.receipts.filter(
    (receipt) => receipt.source?.assignment_idempotency_key === event.idempotency_key,
  );
  if (idempotencyReceipts.some((receipt) => receipt.objective_hash !== hash)) {
    fail("idempotency_conflict", `assignment idempotency key ${event.idempotency_key} maps to another objective`);
  }
  const taskWithIdempotency = [...store.tasks.values()].find(
    (task) => task.idempotency_key === event.idempotency_key,
  );
  if (taskWithIdempotency && taskWithIdempotency.objective_hash !== hash) {
    fail("idempotency_conflict", `assignment idempotency key ${event.idempotency_key} maps to another objective`);
  }
  const existingByTask = store.tasks.get(event.task_id);
  if (existingByTask && existingByTask.objective_hash !== hash) {
    fail("task_identity_conflict", `task id ${event.task_id} maps to another objective`);
  }
  const existing = findTaskByObjective(store.tasks, hash);
  if (
    existing &&
    (existing.task_id !== event.task_id || existing.effective_instruction.instruction_id !== event.event_id)
  ) {
    const receipt = writeReceipt({
      schema: RECEIPT_SCHEMA,
      receipt_type: "duplicate-objective-refused",
      idempotency_key: `event:${event.event_id}:duplicate-objective`,
      task_id: existing.task_id,
      objective_hash: hash,
      revision: null,
      from_state: existing.state,
      to_state: existing.state,
      source: {
        ...source,
        assignment_idempotency_key: event.idempotency_key,
        received_task_id: event.task_id,
      },
      reason: "The objective already has one canonical task record; this assignment cannot create another.",
      authority: null,
      supersedes_instruction_id: null,
      notification_class: "silent",
      recorded_at: now(),
      task_after: null,
    });
    return { kind: "duplicate", receipt };
  }
  let task = existingByTask || existing;
  if (!task) {
    const base = makeBaseTask(event, source);
    const queuedAt = new Date(event.created_at).toISOString();
    const queued = structuredClone(base);
    queued.revision = 1;
    queued.lifecycle_timestamps.queued_at = queuedAt;
    queued.lifecycle_timestamps.updated_at = queuedAt;
    const receipt = applyReceipt({
      schema: RECEIPT_SCHEMA,
      receipt_type: "lifecycle-transition",
      idempotency_key: `event:${event.event_id}:queued`,
      task_id: base.task_id,
      objective_hash: base.objective_hash,
      revision: 1,
      from_state: null,
      to_state: "queued",
      source: { ...source, assignment_idempotency_key: event.idempotency_key },
      reason: "The authenticated upstream assignment entered its durable queue.",
      authority: null,
      supersedes_instruction_id: null,
      notification_class: "silent",
      recorded_at: queuedAt,
      task_after: queued,
    });
    task = receipt.task_after;
  }
  if (task.state === "queued") {
    const delivered = transitionReceipt(task, {
      to: "delivered",
      idempotencyKey: `event:${event.event_id}:delivered`,
      source: { ...source, assignment_idempotency_key: event.idempotency_key },
      reason: "The authenticated assignment reached the durable Firstmate consumer.",
      notificationClass: "silent",
    });
    task = delivered.task_after;
    return { kind: "delivered", task };
  }
  return { kind: "replay", task };
}

function commandIngest(flags) {
  rejectUnknownFlags(flags, new Set(["events"]));
  const eventsPath = flags.events ? resolve(flags.events) : DEFAULT_EVENTS;
  const store = recoverStore({ repair: false });
  if (!existsSync(eventsPath)) {
    process.stdout.write(`${asciiJson({ schema: STATUS_SCHEMA, new_tasks: 0, delivered: 0, duplicates: 0, refused: 0, pending: pendingTasks(store.tasks).length })}\n`);
    return;
  }
  const config = readConfig();
  requireSecureRegularFile(eventsPath, "Hermes ingress event ledger");
  const lines = readFileSync(eventsPath, "utf8").split(/\r?\n/);
  const summary = { schema: STATUS_SCHEMA, new_tasks: 0, delivered: 0, duplicates: 0, refused: 0, pending: 0 };
  const errors = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (!lines[index].trim()) continue;
    let event;
    try {
      event = JSON.parse(lines[index]);
    } catch (error) {
      const payloadHash = createHash("sha256").update(lines[index]).digest("hex");
      const refusal = recordRefusal({
        idempotencyKey: `invalid-line:${payloadHash}`,
        event: null,
        reasonCode: "consumer_schema_drift",
        reason: `Ingress line ${index + 1} is not valid JSON.`,
        payloadHash,
      });
      errors.push(`line ${index + 1}: invalid JSON`);
      if (refusal.isNew) summary.refused += 1;
      continue;
    }
    const rawHash = hashValue(event);
    if (event.event_type === "captain_fleet_reply") {
      const refusal = recordRefusal({
        idempotencyKey: `relay-refusal:${event.event_id || rawHash}`,
        event,
        reasonCode: "unverified_relay_captain",
        reason: "Relayed captain text has no trusted-channel captain identity and cannot grant, widen, or apply authority.",
        payloadHash: rawHash,
      });
      if (refusal.isNew) summary.refused += 1;
      continue;
    }
    if (event.event_type !== "mercury_engineering_assignment") {
      const refusal = recordRefusal({
        idempotencyKey: `schema-refusal:${event.event_id || rawHash}`,
        event,
        reasonCode: "consumer_schema_drift",
        reason: `Unsupported ingress event_type on line ${index + 1}.`,
        payloadHash: rawHash,
      });
      errors.push(`line ${index + 1}: unsupported event_type`);
      if (refusal.isNew) summary.refused += 1;
      continue;
    }
    try {
      validateMercuryEvent(config, event, index + 1);
      const before = recoverStore({ repair: false });
      const result = ingestMercury(event, before);
      if (result.kind === "delivered") {
        summary.new_tasks += before.tasks.has(event.task_id) ? 0 : 1;
        summary.delivered += 1;
      } else if (result.kind === "duplicate") summary.duplicates += 1;
    } catch (error) {
      if (!(error instanceof AuthorityError)) throw error;
      const refusal = recordRefusal({
        idempotencyKey: `mercury-refusal:${event.event_id || rawHash}`,
        event,
        reasonCode: error.code,
        reason: error.message,
        payloadHash: rawHash,
      });
      errors.push(`line ${index + 1}: ${error.code}: ${error.message}`);
      if (refusal.isNew) summary.refused += 1;
    }
  }
  const finalStore = recoverStore({ repair: false });
  summary.pending = pendingTasks(finalStore.tasks).length;
  process.stdout.write(`${asciiJson(summary)}\n`);
  if (errors.length > 0) fail("ingress_refused", errors.join("; "));
}

function commandAccept(flags) {
  rejectUnknownFlags(flags, new Set(["task-id", "decision-key", "owner", "assessment", "boundaries"]));
  const taskId = requireFlag(flags, "task-id", 100);
  const decisionKey = requireFlag(flags, "decision-key", 300);
  const owner = requireFlag(flags, "owner", 500);
  const assessment = requireFlag(flags, "assessment", 2000);
  const boundaries = parseBoundaries(requireFlag(flags, "boundaries", 500), { allowNone: true });
  if (boundaries.length !== 0) fail("captain_required", "Mercury standing authority applies only when the assessed higher-boundary list is none");
  const config = readConfig();
  const store = recoverStore({ repair: false });
  const operation = { command: "accept", task_id: taskId, owner, assessment, boundaries };
  const replay = replayForCommand(`accept:${decisionKey}`, store.receipts, taskId, operation);
  if (replay) {
    process.stdout.write(`${asciiJson(publicReceipt(replay), true)}\n`);
    return;
  }
  const task = store.tasks.get(taskId);
  if (!task) fail("task_not_found", `task not found: ${taskId}`);
  if (task.source_identity.principal !== "mercury" || !task.source_identity.identity_verified) {
    fail("authority_rejected", "ordinary reversible standing authority requires a verified Mercury source task");
  }
  validateMercurySource(config, task.source_identity.identity, task.source_identity.identity_key_id);
  if (task.authority.captain_required_boundaries.length > 0) {
    fail("captain_required", "task already carries higher-boundary holds that only a direct captain instruction can clear");
  }
  if (!["delivered", "blocked"].includes(task.state) || task.lifecycle_timestamps.accepted_at) {
    fail("invalid_transition", `task cannot be accepted explicitly from ${task.state}`);
  }
  if (task.effective_instruction.principal === "captain") {
    fail("captain_precedence", "Mercury standing authority cannot accept or displace current captain direction");
  }
  const receipt = transitionReceipt(task, {
    to: "accepted",
    idempotencyKey: `accept:${decisionKey}`,
    source: { principal: "firstmate", channel: "local", conversation: "authority-decision" },
    reason: assessment,
    authority: { basis: "mercury-standing-ordinary-reversible", boundaries: [] },
    notificationClass: "acceptance",
    operationHash: hashValue(operation),
    mutate(next) {
      next.owner = owner;
      next.authority = {
        basis: "mercury-standing-ordinary-reversible",
        assessed_by: "firstmate",
        assessment,
        captain_required_boundaries: [],
        captain_authorized_boundaries: [],
      };
    },
  });
  process.stdout.write(`${asciiJson(publicReceipt(receipt), true)}\n`);
}

function commandHold(flags) {
  rejectUnknownFlags(flags, new Set(["task-id", "decision-key", "boundaries", "reason"]));
  const taskId = requireFlag(flags, "task-id", 100);
  const decisionKey = requireFlag(flags, "decision-key", 300);
  const boundaries = parseBoundaries(requireFlag(flags, "boundaries", 500));
  const reason = requireFlag(flags, "reason", 2000);
  const store = recoverStore({ repair: false });
  const operation = { command: "hold", task_id: taskId, boundaries, reason };
  const replay = replayForCommand(`hold:${decisionKey}`, store.receipts, taskId, operation);
  if (replay) {
    process.stdout.write(`${asciiJson(publicReceipt(replay), true)}\n`);
    return;
  }
  const task = store.tasks.get(taskId);
  if (!task) fail("task_not_found", `task not found: ${taskId}`);
  if (TERMINAL_STATES.has(task.state)) fail("invalid_transition", `terminal task cannot be held from ${task.state}`);
  const receipt = transitionReceipt(task, {
    to: "blocked",
    idempotencyKey: `hold:${decisionKey}`,
    source: { principal: "firstmate", channel: "local", conversation: "authority-decision" },
    reason,
    authority: { basis: "captain-required-higher-boundary", boundaries },
    notificationClass: "captain-decision",
    operationHash: hashValue(operation),
    mutate(next, timestamp) {
      next.authority.assessed_by = "firstmate";
      next.authority.assessment = reason;
      next.blockers = addConstraints(
        next.blockers,
        boundaries.map((boundary) => ({
          kind: "captain-approval",
          reason,
          boundaries: [boundary],
          recorded_at: timestamp,
        })),
      );
    },
  });
  process.stdout.write(`${asciiJson(publicReceipt(receipt), true)}\n`);
}

function allowedTransition(from, to) {
  const allowed = {
    accepted: new Set(["running", "blocked", "failed", "completed"]),
    running: new Set(["blocked", "failed", "completed"]),
    blocked: new Set(["running", "failed", "completed"]),
  };
  return allowed[from]?.has(to) || false;
}

function commandTransition(flags) {
  rejectUnknownFlags(
    flags,
    new Set(["task-id", "transition-key", "to", "reason", "owner", "artifacts-json", "verification-json"]),
  );
  const taskId = requireFlag(flags, "task-id", 100);
  const transitionKey = requireFlag(flags, "transition-key", 300);
  const to = requireFlag(flags, "to", 50);
  if (!["running", "blocked", "failed", "completed"].includes(to)) fail("invalid_transition", `unsupported lifecycle destination: ${to}`);
  const reason = flags.reason ? boundedText(flags.reason, "--reason", 4000) : "Lifecycle transition recorded by Firstmate.";
  if (["blocked", "failed", "completed"].includes(to) && !flags.reason) fail("usage", `--reason is required for ${to}`);
  const artifacts = normalizeEvidence(parseJsonArray(flags["artifacts-json"] || "[]", "artifacts-json"), "artifacts", ["label", "ref"]);
  const verification = normalizeEvidence(
    parseJsonArray(flags["verification-json"] || "[]", "verification-json"),
    "verification",
    ["check", "status", "evidence"],
  );
  for (const row of verification) {
    if (!["passed", "failed", "not_run"].includes(row.status)) fail("invalid_input", "verification status must be passed, failed, or not_run");
  }
  if (to === "completed" && (artifacts.length === 0 || verification.length === 0)) {
    fail("invalid_transition", "completed requires at least one artifact and one verification result");
  }
  const owner = flags.owner ? boundedText(flags.owner, "--owner", 500) : null;
  const operation = { command: "transition", task_id: taskId, to, reason, owner, artifacts, verification };
  const store = recoverStore({ repair: false });
  const replay = replayForCommand(`transition:${transitionKey}`, store.receipts, taskId, operation);
  if (replay) {
    process.stdout.write(`${asciiJson(publicReceipt(replay), true)}\n`);
    return;
  }
  const task = store.tasks.get(taskId);
  if (!task) fail("task_not_found", `task not found: ${taskId}`);
  if (!allowedTransition(task.state, to)) fail("invalid_transition", `task cannot transition from ${task.state} to ${to}`);
  if (!task.lifecycle_timestamps.accepted_at) fail("acceptance_inferred", `${to} requires an explicit accepted transition receipt`);
  if (task.blockers.some((constraint) => ["captain-pause", "captain-approval"].includes(constraint.kind)) && to !== "blocked") {
    fail("captain_precedence", "task cannot advance while a captain constraint is effective");
  }
  const receipt = transitionReceipt(task, {
    to,
    idempotencyKey: `transition:${transitionKey}`,
    source: { principal: "firstmate", channel: "local", conversation: "task-lifecycle" },
    reason,
    notificationClass: ["failed", "completed"].includes(to) ? "terminal" : "silent",
    operationHash: hashValue(operation),
    mutate(next, timestamp) {
      if (owner) next.owner = owner;
      if (to === "blocked") {
        next.blockers = addConstraints(next.blockers, [{ kind: "operational", reason, boundaries: [], recorded_at: timestamp }]);
      } else {
        next.blockers = removeConstraints(next.blockers, (constraint) => constraint.kind === "operational");
      }
      if (artifacts.length > 0) next.artifacts = artifacts;
      if (verification.length > 0) next.verification = verification;
      if (["failed", "completed"].includes(to)) next.terminal_result = reason;
    },
  });
  process.stdout.write(`${asciiJson(publicReceipt(receipt), true)}\n`);
}

function recordedCaptainSource(config, conversation, message) {
  const [{ identity, channel }] = config.captain_sources;
  return {
    principal: "captain",
    identity,
    identity_key_id: null,
    identity_verified: true,
    verification: "recorded-by-firstmate-trusted-session",
    channel,
    conversation,
    message,
  };
}

function firstmateRecorderSource(captainSource, instructionId) {
  return {
    principal: "firstmate",
    identity: "firstmate",
    identity_key_id: null,
    identity_verified: true,
    verification: "local-firstmate-session-recorder",
    channel: "local",
    conversation: captainSource.conversation,
    message: captainSource.message,
    instruction_id: instructionId,
    recorded_principal: "captain",
    recorded_identity: captainSource.identity,
    recorded_channel: captainSource.channel,
  };
}

function commandRecordCaptainTask(flags) {
  rejectUnknownFlags(
    flags,
    new Set([
      "task-id",
      "idempotency-key",
      "instruction-id",
      "source-conversation",
      "source-message",
      "objective",
      "acceptance-json",
      "repository",
      "priority",
      "owner",
      "authorized-boundaries",
    ]),
  );
  const config = readConfig();
  const instructionId = requireFlag(flags, "instruction-id", 300);
  const sourceConversation = requireFlag(flags, "source-conversation", 500);
  const sourceMessage = flags["source-message"]
    ? boundedText(flags["source-message"], "--source-message", 500)
    : instructionId;
  const captainSource = recordedCaptainSource(config, sourceConversation, sourceMessage);
  const recorder = firstmateRecorderSource(captainSource, instructionId);
  const objective = requireFlag(flags, "objective", 12000);
  const event = {
    task_id: flags["task-id"] || randomUUID(),
    idempotency_key: requireFlag(flags, "idempotency-key", 200),
    objective,
    acceptance_criteria: boundedList(parseJsonArray(requireFlag(flags, "acceptance-json", 24000), "acceptance-json", { allowEmpty: false }), "acceptance_criteria", 20, 1000),
    repository_ref: requireFlag(flags, "repository", 500),
    priority: requireFlag(flags, "priority", 50),
  };
  if (!UUID_RE.test(event.task_id)) fail("invalid_input", "--task-id must be a UUID");
  if (!PRIORITIES.has(event.priority)) fail("invalid_input", "priority must be low, normal, high, or urgent");
  const owner = requireFlag(flags, "owner", 500);
  const authorized = parseBoundaries(flags["authorized-boundaries"] || "none", { allowNone: true });
  const store = recoverStore({ repair: false });
  const hash = objectiveHash(objective);
  const taskWithIdempotency = [...store.tasks.values()].find(
    (task) => task.idempotency_key === event.idempotency_key,
  );
  if (taskWithIdempotency && taskWithIdempotency.objective_hash !== hash) {
    fail("idempotency_conflict", `assignment idempotency key ${event.idempotency_key} maps to another objective`);
  }
  const operation = {
    command: "record-captain-task",
    task_id: flags["task-id"] || null,
    instruction_id: instructionId,
    event: { ...event, task_id: flags["task-id"] || null },
    owner,
    authorized_boundaries: authorized,
    captain_identity: captainSource.identity,
  };
  const replayKey = `captain-record-task:${event.idempotency_key}:accepted`;
  const existingReplay = receiptForKey(replayKey, store.receipts);
  const replay = existingReplay
    ? replayForCommand(replayKey, store.receipts, flags["task-id"] || existingReplay.task_id, operation)
    : null;
  if (replay) {
    process.stdout.write(`${asciiJson(publicReceipt(replay), true)}\n`);
    return;
  }
  const existing = findTaskByObjective(store.tasks, hash);
  if (
    existing &&
    existing.idempotency_key === event.idempotency_key &&
    existing.effective_instruction.instruction_id === instructionId
  ) {
    const queuedReplay = replayForCommand(
      `captain-record-task:${event.idempotency_key}:queued`,
      store.receipts,
      existing.task_id,
      operation,
    );
    if (!queuedReplay) fail("task_drift", "captain submission task exists without its queued receipt");
    let current = existing;
    if (current.state === "queued") {
      current = transitionReceipt(current, {
        to: "delivered",
        idempotencyKey: `captain-record-task:${event.idempotency_key}:delivered`,
        source: recorder,
        reason: "Firstmate durably recorded the direct captain instruction.",
        operationHash: hashValue(operation),
      }).task_after;
    }
    if (current.state === "delivered") {
      const accepted = transitionReceipt(current, {
        to: "accepted",
        idempotencyKey: `captain-record-task:${event.idempotency_key}:accepted`,
        source: recorder,
        reason: "Firstmate explicitly accepted the directly confirmed captain instruction.",
        authority: { basis: "captain-direct", boundaries: authorized },
        notificationClass: "acceptance",
        operationHash: hashValue(operation),
        mutate(next) {
          next.owner = owner;
          next.authority = {
            basis: "captain-direct",
            assessed_by: "captain",
            assessment: "Direct trusted-channel instruction.",
            captain_required_boundaries: [],
            captain_authorized_boundaries: authorized,
          };
        },
      });
      process.stdout.write(`${asciiJson(publicReceipt(accepted), true)}\n`);
      return;
    }
    fail("task_drift", "captain submission is partially recorded in an unsupported lifecycle state");
  }
  if (existing) {
    fail("duplicate_objective", "objective already has a canonical task; record a bounded captain decision instead");
  }
  const captainTaskSource = { ...captainSource, instruction_id: instructionId };
  const base = makeBaseTask(event, captainTaskSource);
  const timestamp = now();
  const queued = structuredClone(base);
  queued.revision = 1;
  queued.lifecycle_timestamps.queued_at = timestamp;
  queued.lifecycle_timestamps.updated_at = timestamp;
  let receipt = applyReceipt({
    schema: RECEIPT_SCHEMA,
    receipt_type: "lifecycle-transition",
    idempotency_key: `captain-record-task:${event.idempotency_key}:queued`,
    task_id: base.task_id,
    objective_hash: base.objective_hash,
    revision: 1,
    from_state: null,
    to_state: "queued",
    source: recorder,
    reason: "Firstmate recorded a direct captain instruction into the durable queue.",
    authority: { basis: "captain-direct", boundaries: authorized },
    supersedes_instruction_id: null,
    notification_class: "silent",
    operation_hash: hashValue(operation),
    recorded_at: timestamp,
    task_after: queued,
  });
  if (runtimeHooks.afterCaptainTaskQueued?.(publicReceipt(receipt)) === true) {
    process.stdout.write(`${asciiJson(publicReceipt(receipt), true)}\n`);
    return;
  }
  receipt = transitionReceipt(receipt.task_after, {
    to: "delivered",
    idempotencyKey: `captain-record-task:${event.idempotency_key}:delivered`,
    source: recorder,
    reason: "Firstmate durably recorded the direct captain instruction.",
    operationHash: hashValue(operation),
  });
  receipt = transitionReceipt(receipt.task_after, {
    to: "accepted",
    idempotencyKey: `captain-record-task:${event.idempotency_key}:accepted`,
    source: recorder,
    reason: "Firstmate explicitly accepted the directly confirmed captain instruction.",
    authority: { basis: "captain-direct", boundaries: authorized },
    notificationClass: "acceptance",
    operationHash: hashValue(operation),
    mutate(next) {
      next.owner = owner;
      next.authority = {
        basis: "captain-direct",
        assessed_by: "captain",
        assessment: "Direct trusted-channel instruction.",
        captain_required_boundaries: [],
        captain_authorized_boundaries: authorized,
      };
    },
  });
  process.stdout.write(`${asciiJson(publicReceipt(receipt), true)}\n`);
}

function commandRecordCaptainDecision(flags) {
  rejectUnknownFlags(
    flags,
    new Set([
      "task-id",
      "action",
      "instruction-id",
      "source-conversation",
      "source-message",
      "direction",
      "supersedes",
      "authorized-boundaries",
      "owner",
    ]),
  );
  const config = readConfig();
  const taskId = requireFlag(flags, "task-id", 100);
  const action = requireFlag(flags, "action", 50);
  if (!["pause", "override", "narrow", "cancel"].includes(action)) fail("invalid_input", "captain action must be pause, override, narrow, or cancel");
  const instructionId = requireFlag(flags, "instruction-id", 300);
  const sourceConversation = requireFlag(flags, "source-conversation", 500);
  const sourceMessage = flags["source-message"]
    ? boundedText(flags["source-message"], "--source-message", 500)
    : instructionId;
  const captainSource = recordedCaptainSource(config, sourceConversation, sourceMessage);
  const recorder = firstmateRecorderSource(captainSource, instructionId);
  const direction = requireFlag(flags, "direction", 12000);
  const authorized = parseBoundaries(flags["authorized-boundaries"] || "none", { allowNone: true });
  const suppliedSupersedes = flags.supersedes ? boundedText(flags.supersedes, "--supersedes", 300) : null;
  const owner = flags.owner ? boundedText(flags.owner, "--owner", 500) : null;
  const store = recoverStore({ repair: false });
  const operation = {
    command: "record-captain-decision",
    task_id: taskId,
    action,
    instruction_id: instructionId,
    direction,
    supersedes: suppliedSupersedes,
    authorized_boundaries: authorized,
    owner,
    captain_identity: captainSource.identity,
  };
  const replay = replayForCommand(`captain-record-decision:${instructionId}`, store.receipts, taskId, operation);
  if (replay) {
    process.stdout.write(`${asciiJson(publicReceipt(replay), true)}\n`);
    return;
  }
  const task = store.tasks.get(taskId);
  if (!task) fail("task_not_found", `task not found: ${taskId}`);
  const currentInstruction = task.effective_instruction.instruction_id;
  const pauseConstraint = task.blockers.find((constraint) => constraint.kind === "captain-pause") || null;
  const validSupersessionTargets = new Set([currentInstruction, pauseConstraint?.instruction_id].filter(Boolean));
  if (suppliedSupersedes && !validSupersessionTargets.has(suppliedSupersedes)) {
    fail("cross_task_authorization_rejected", "captain supersession reference does not match this task's current instruction");
  }
  const changesDirection = ["override", "narrow"].includes(action);
  const clearsCaptainPause = Boolean(
    changesDirection && pauseConstraint && suppliedSupersedes === pauseConstraint.instruction_id,
  );
  let nextConstraints = task.blockers;
  if (action === "pause") {
    nextConstraints = addConstraints(task.blockers, [
      {
        kind: "captain-pause",
        reason: direction,
        boundaries: [],
        recorded_at: now(),
        instruction_id: instructionId,
      },
    ]);
  } else if (action === "cancel") {
    nextConstraints = [];
  } else if (changesDirection) {
    nextConstraints = removeConstraints(
      task.blockers,
      (constraint) =>
        (constraint.kind === "captain-pause" && clearsCaptainPause) ||
        (constraint.kind === "captain-approval" && authorized.includes(constraint.boundaries[0])),
    );
  }
  const remainingCaptainConstraints = nextConstraints.filter((constraint) =>
    ["captain-pause", "captain-approval"].includes(constraint.kind),
  );
  const recordsAcceptance = Boolean(
    changesDirection && !task.lifecycle_timestamps.accepted_at && remainingCaptainConstraints.length === 0,
  );
  let progressState = task.progress_state;
  if (action === "cancel") progressState = "cancelled";
  else if (recordsAcceptance) progressState = "accepted";
  if (recordsAcceptance && !owner && !task.owner) {
    fail("usage", "--owner is required when direct captain direction accepts a delivered task");
  }
  if (TERMINAL_STATES.has(task.progress_state) && progressState !== task.progress_state) {
    fail("invalid_transition", "a terminal task cannot be reopened by this command");
  }
  const receipt = transitionReceipt(task, {
    to: progressState,
    receiptType: "captain-directive",
    idempotencyKey: `captain-record-decision:${instructionId}`,
    source: recorder,
    reason: direction,
    authority: { basis: "captain-direct", boundaries: authorized, action },
    supersedesInstructionId: suppliedSupersedes || currentInstruction,
    notificationClass: "captain-direction",
    operationHash: hashValue(operation),
    mutate(next, timestamp) {
      next.effective_instruction = {
        instruction_id: instructionId,
        principal: "captain",
        action,
        direction,
        source_channel: captainSource.channel,
        source_conversation: captainSource.conversation,
      };
      if (owner) next.owner = owner;
      next.blockers = nextConstraints.map((constraint) =>
        constraint.kind === "captain-pause" && constraint.instruction_id === instructionId
          ? { ...constraint, recorded_at: timestamp }
          : constraint,
      );
      if (action === "cancel") {
        next.terminal_result = direction;
      } else if (changesDirection) {
        next.authority.captain_authorized_boundaries = [
          ...new Set([...next.authority.captain_authorized_boundaries, ...authorized]),
        ].sort();
        next.authority.basis = "captain-direct";
        next.authority.assessed_by = "captain";
        next.authority.assessment = direction;
      }
    },
  });
  process.stdout.write(`${asciiJson(publicReceipt(receipt), true)}\n`);
}

function pendingTasks(tasks) {
  return [...tasks.values()].filter(
    (task) => task.state === "delivered" || task.authority.captain_required_boundaries.length > 0,
  );
}

function taskSummary(task) {
  return {
    task_id: task.task_id,
    idempotency_key: task.idempotency_key,
    source_identity: task.source_identity,
    source_conversation: task.source_conversation,
    objective: task.objective,
    acceptance_criteria: task.acceptance_criteria,
    repository: task.repository,
    priority: task.priority,
    progress_state: task.progress_state,
    state: task.state,
    lifecycle_timestamps: task.lifecycle_timestamps,
    owner: task.owner,
    blockers: task.blockers,
    artifacts: task.artifacts,
    verification: task.verification,
    terminal_result: task.terminal_result,
    authority: task.authority,
    effective_instruction: task.effective_instruction,
    revision: task.revision,
  };
}

function publicReceipt(receipt) {
  const result = structuredClone(receipt);
  delete result.task_after;
  return result;
}

function commandStatus(flags) {
  rejectUnknownFlags(flags, new Set(["task-id", "objective", "pending", "refusals", "limit", "viewer"]));
  if (flags.viewer && !["captain", "mercury"].includes(flags.viewer)) fail("invalid_input", "viewer must be captain or mercury");
  const selectors = [flags["task-id"], flags.objective, flags.pending, flags.refusals].filter(Boolean);
  if (selectors.length > 1) fail("usage", "choose only one status selector");
  const limit = flags.limit ? Number.parseInt(flags.limit, 10) : 20;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100) fail("invalid_input", "limit must be 1 to 100");
  const store = recoverStore({ repair: false });
  if (flags.refusals) {
    const rows = store.receipts.filter((receipt) => receipt.receipt_type === "refusal").sort(receiptOrder);
    const shown = rows.slice(-limit).map(publicReceipt);
    process.stdout.write(`${asciiJson({ schema: STATUS_SCHEMA, refusals: shown, receipts_omitted: rows.length - shown.length }, true)}\n`);
    return;
  }
  if (flags.pending) {
    const rows = pendingTasks(store.tasks).sort((left, right) => left.task_id.localeCompare(right.task_id));
    const shown = rows.slice(0, limit).map(taskSummary);
    process.stdout.write(`${asciiJson({ schema: STATUS_SCHEMA, tasks: shown, tasks_omitted: rows.length - shown.length }, true)}\n`);
    return;
  }
  let task = null;
  if (flags["task-id"]) task = store.tasks.get(flags["task-id"]);
  else if (flags.objective) task = findTaskByObjective(store.tasks, objectiveHash(flags.objective));
  if (flags["task-id"] || flags.objective) {
    if (!task) fail("task_not_found", "status selector did not match a canonical task");
    const receipts = store.receipts.filter((receipt) => receipt.task_id === task.task_id).sort(receiptOrder);
    const shown = receipts.slice(-limit).map(publicReceipt);
    process.stdout.write(
      `${asciiJson({ schema: STATUS_SCHEMA, task: taskSummary(task), receipts: shown, receipts_omitted: receipts.length - shown.length }, true)}\n`,
    );
    return;
  }
  const rows = [...store.tasks.values()].sort((left, right) => left.task_id.localeCompare(right.task_id));
  const shown = rows.slice(0, limit).map(taskSummary);
  process.stdout.write(`${asciiJson({ schema: STATUS_SCHEMA, tasks: shown, tasks_omitted: rows.length - shown.length }, true)}\n`);
}

function receiptOrder(left, right) {
  const leftRevision = left.revision ?? Number.MAX_SAFE_INTEGER;
  const rightRevision = right.revision ?? Number.MAX_SAFE_INTEGER;
  return leftRevision - rightRevision || left.recorded_at.localeCompare(right.recorded_at) || left.receipt_id.localeCompare(right.receipt_id);
}

function commandHealth(flags) {
  rejectUnknownFlags(flags, new Set());
  readConfig();
  const store = recoverStore({ repair: false });
  process.stdout.write(`${asciiJson({ schema: STATUS_SCHEMA, healthy: true, tasks: store.tasks.size, receipts: store.receipts.length })}\n`);
}

function commandRecover(flags) {
  rejectUnknownFlags(flags, new Set());
  readConfig();
  const store = recoverStore({ repair: true });
  process.stdout.write(`${asciiJson({ schema: STATUS_SCHEMA, recovered: true, tasks: store.tasks.size, receipts: store.receipts.length })}\n`);
}

function printIngressHelp() {
  process.stdout.write(`fm-principal-authority.sh commands:\n\n`);
  process.stdout.write(`  ingest [--events <jsonl>]\n`);
  process.stdout.write(`  accept --task-id <uuid> --decision-key <key> --owner <owner> --assessment <reason> --boundaries none\n`);
  process.stdout.write(`  hold --task-id <uuid> --decision-key <key> --boundaries <comma-list> --reason <reason>\n`);
  process.stdout.write(`  transition --task-id <uuid> --transition-key <key> --to <running|blocked|failed|completed>\n`);
  process.stdout.write(`    [--reason <text>] [--owner <owner>] [--artifacts-json <array>] [--verification-json <array>]\n`);
  process.stdout.write(`  status [--task-id <uuid>|--objective <text>|--pending|--refusals] [--limit <1-100>]\n`);
  process.stdout.write(`  health\n  recover\n\n`);
  process.stdout.write(`Captain claims are never admitted on this surface.\n`);
  process.stdout.write(`Higher boundaries: ${[...HIGHER_BOUNDARIES].sort().join(", ")}\n`);
}

function printTrustedSessionHelp() {
  process.stdout.write(`fm-principal-session-authority.sh commands:\n\n`);
  process.stdout.write(`  record-captain-task --idempotency-key <key> --instruction-id <id> --objective <text>\n`);
  process.stdout.write(`    --acceptance-json <array> --repository <ref> --priority <priority> --owner <owner>\n`);
  process.stdout.write(`    --source-conversation <ref> [--source-message <ref>] [--task-id <uuid>]\n`);
  process.stdout.write(`    [--authorized-boundaries <comma-list|none>]\n`);
  process.stdout.write(`  record-captain-decision --task-id <uuid> --action <pause|override|narrow|cancel>\n`);
  process.stdout.write(`    --instruction-id <id> --source-conversation <ref> --direction <text>\n`);
  process.stdout.write(`    [--source-message <ref>] [--supersedes <instruction-id>]\n`);
  process.stdout.write(`    [--authorized-boundaries <comma-list|none>] [--owner <owner>]\n\n`);
  process.stdout.write(`This local administrative surface records decisions Firstmate already received in its trusted captain session.\n`);
  process.stdout.write(`It is not an identity admission or relay ingress surface.\n`);
  process.stdout.write(`Higher boundaries: ${[...HIGHER_BOUNDARIES].sort().join(", ")}\n`);
}

function main(argv, surface) {
  const { command, flags } = parseArguments(argv);
  ensureDirectories();
  if (command === "help") {
    if (surface === "trusted-session") printTrustedSessionHelp();
    else printIngressHelp();
    return;
  }
  if (surface === "trusted-session") {
    switch (command) {
      case "record-captain-task":
        commandRecordCaptainTask(flags);
        return;
      case "record-captain-decision":
        commandRecordCaptainDecision(flags);
        return;
      default:
        fail("usage", `unknown trusted-session command: ${command}`);
    }
  }
  switch (command) {
    case "ingest":
      commandIngest(flags);
      return;
    case "accept":
      commandAccept(flags);
      return;
    case "hold":
      commandHold(flags);
      return;
    case "transition":
      commandTransition(flags);
      return;
    case "status":
      commandStatus(flags);
      return;
    case "health":
      commandHealth(flags);
      return;
    case "recover":
      commandRecover(flags);
      return;
    default:
      fail("usage", `unknown command: ${command}`);
  }
}

function reportCliError(error) {
  if (error instanceof AuthorityError) {
    process.stderr.write(`fm-principal-authority: ${error.code}: ${error.message}\n`);
    process.exitCode = error.code === "usage" ? 2 : 1;
  } else {
    process.stderr.write(`fm-principal-authority: internal_error: ${error.stack || error.message}\n`);
    process.exitCode = 1;
  }
}

export function executeIngressCli(argv) {
  try {
    main(argv, "ingress");
  } catch (error) {
    reportCliError(error);
  }
}

export function executeTrustedSessionCli(argv, hooks = {}) {
  const previous = runtimeHooks;
  runtimeHooks = Object.freeze({ ...hooks });
  try {
    main(argv, "trusted-session");
  } catch (error) {
    reportCliError(error);
  } finally {
    runtimeHooks = previous;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === MODULE_PATH) {
  executeIngressCli(process.argv.slice(2));
}
