import { createAgentHandler } from "./handler.ts";
import type { AgentHandlerOptions } from "./handler.ts";
import {
  createReadRepository,
  createToolRunner,
  resolveCalendar,
  readWithDeadline,
} from "./repository.ts";
import type { ReadClient } from "./repository.ts";
import { FinanceError } from "./finance.ts";
import { searchPlaces } from "./places.ts";

export interface AgentClient extends ReadClient {
  auth: {
    getUser(
      token: string,
    ): Promise<{
      data: { user: { id: string; role?: string } | null };
      error: unknown;
    }>;
  };
}
export interface ServerOptions {
  url?: string;
  anonKey?: string;
  apiKey?: string;
  model?: string;
  placesKey?: string;
  clientFactory: (
    url: string,
    key: string,
    options: {
      global: { headers: { Authorization: string } };
      auth: {
        persistSession: false;
        autoRefreshToken: false;
        detectSessionInUrl: false;
      };
    },
  ) => AgentClient;
  fetchImpl?: typeof fetch;
  now?: () => Date;
}
export function createServerAgent(options: ServerOptions) {
  const authorize: AgentHandlerOptions["authorize"] = async (authorization) => {
    if (!options.url || !options.anonKey)
      throw new Error("Backend is unavailable.");
    const db = options.clientFactory(options.url, options.anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    });
    const { data, error } = await readWithDeadline(
      db.auth.getUser(authorization.replace(/^Bearer\s+/i, "")),
    );
    if (
      error ||
      !data.user ||
      data.user.role !== "authenticated" ||
      !data.user.id
    )
      return null;
    const owner = data.user.id;
    return {
      prepareTools: async (calendarInput, now) => {
        try {
          const calendar = resolveCalendar(calendarInput, now);
          return {
            runTool: createToolRunner(
              createReadRepository(db, owner),
              calendar,
              (input) =>
                searchPlaces(input, {
                  apiKey: options.placesKey,
                  fetchImpl: options.fetchImpl,
                }),
            ),
          };
        } catch (error) {
          if (error instanceof FinanceError)
            return { error: error.code, message: error.message };
          throw error;
        }
      },
    };
  };
  return createAgentHandler({
    authorize,
    apiKey: options.apiKey,
    model: options.model,
    fetchImpl: options.fetchImpl,
    now: options.now,
  });
}
