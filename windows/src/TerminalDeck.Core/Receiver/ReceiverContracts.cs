using System.Text.Json;
using TerminalDeck.Core.Mcp;
namespace TerminalDeck.Core.Receiver;
public static class ReceiverContracts
{
  public static IReadOnlyList<McpToolSpec> Specs { get; } = Load();
  private static IReadOnlyList<McpToolSpec> Load()
  {
    using var doc = JsonDocument.Parse(Data);
    return doc.RootElement.GetProperty("entries").EnumerateArray().Select(r => new McpToolSpec(r.GetProperty("id").GetString()!, r.GetProperty("wire").GetString()!, Enum.Parse<McpTier>(r.GetProperty("tier").GetString()!, true), r.GetProperty("inputSchema").Clone())).ToArray();
  }
  private const string Data = """
{
  "entries": [
    {
      "id": "receiver.events",
      "wire": "receiver_events",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {
          "source": {
            "type": "string"
          },
          "status": {
            "type": "string",
            "enum": [
              "unrouted",
              "held",
              "delivered",
              "failed",
              "duplicate",
              "ignored",
              "rejected"
            ]
          },
          "query": {
            "type": "string"
          },
          "limit": {
            "type": "integer",
            "minimum": 1,
            "maximum": 200
          }
        },
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.event",
      "wire": "receiver_event",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string"
          }
        },
        "required": [
          "id"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.sources",
      "wire": "receiver_sources",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {},
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.rules",
      "wire": "receiver_rules",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {},
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.test",
      "wire": "receiver_test",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {
          "rule": {
            "type": "object",
            "description": "Windows routing rule. Matches title or text with contains. It proposes a destination; sending still needs approval.",
            "properties": {
              "id": {
                "type": "string",
                "maxLength": 128
              },
              "name": {
                "type": "string",
                "maxLength": 120
              },
              "sourceId": {
                "type": [
                  "string",
                  "null"
                ],
                "maxLength": 128
              },
              "contains": {
                "type": "string",
                "maxLength": 1000
              },
              "target": {
                "type": "object",
                "properties": {
                  "kind": {
                    "type": "string",
                    "enum": [
                      "session",
                      "chat",
                      "newTask",
                      "hoot",
                      "agent"
                    ]
                  },
                  "id": {
                    "type": [
                      "string",
                      "null"
                    ],
                    "maxLength": 128
                  },
                  "threadKey": {
                    "type": [
                      "string",
                      "null"
                    ],
                    "maxLength": 128
                  }
                },
                "required": [
                  "kind"
                ],
                "additionalProperties": false
              },
              "enabled": {
                "type": "boolean"
              },
              "perHour": {
                "type": "integer",
                "minimum": 1,
                "maximum": 1000
              },
              "conditions": {
                "type": "array", "maxItems": 32,
                "items": {
                  "type": "object", "additionalProperties": false,
                  "properties": {
                    "path": { "type": "string", "minLength": 1, "maxLength": 240 },
                    "operation": { "type": "string", "enum": ["is", "isNot", "contains", "doesNotContain", "startsWith", "matchesPattern", "isPresent", "isMissing", "isOneOf", "isAbove", "isBelow", "isAtLeast"] },
                    "value": { "type": "string", "maxLength": 1000 }
                  },
                  "required": ["path", "operation"]
                }
              },
              "quietStartHour": {
                "type": [
                  "integer",
                  "null"
                ],
                "minimum": 0,
                "maximum": 23
              },
              "quietEndHour": {
                "type": [
                  "integer",
                  "null"
                ],
                "minimum": 0,
                "maximum": 23
              }
            },
            "required": [
              "id",
              "name",
              "contains",
              "target"
            ],
            "additionalProperties": false
          },
          "eventId": {
            "type": "string"
          },
          "sourceId": {
            "type": "string"
          },
          "sample": {
            "type": "string",
            "description": "A sample message body. It is treated as outside text and is never sent."
          }
        },
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.source_check",
      "wire": "receiver_source_check",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {
          "sourceId": {
            "type": "string"
          },
          "eventId": {
            "type": "string"
          },
          "sample": {
            "type": "string",
            "description": "A sample message body. It is treated as outside text and is never sent."
          }
        },
        "required": [
          "sourceId"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.source_change",
      "wire": "receiver_source_change",
      "tier": "alter",
      "inputSchema": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": [
              "create",
              "update",
              "pause",
              "resume",
              "delete",
              "rotate"
            ]
          },
          "projectId": {
            "type": "string"
          },
          "projectScope": {
            "type": "string",
            "enum": [
              "all",
              "project"
            ]
          },
          "type": {
            "type": "string"
          },
          "preset": {
            "type": "string"
          },
          "name": {
            "type": "string"
          },
          "source": {
            "type": "object",
            "description": "Windows source record. Connection keys are managed separately and are never returned to tools.",
            "properties": {
              "id": {
                "type": "string",
                "maxLength": 128
              },
              "name": {
                "type": "string",
                "maxLength": 120
              },
              "kind": {
                "type": "string",
                "enum": [
                  "share",
                  "drop",
                  "clipboard",
                  "browser",
                  "phone",
                  "report",
                  "hoot",
                  "webhook"
                ]
              },
              "projectId": {
                "type": "string",
                "maxLength": 128
              },
              "enabled": {
                "type": "boolean"
              }
            },
            "required": [
              "id",
              "name",
              "kind",
              "projectId"
            ],
            "additionalProperties": false
          },
          "id": {
            "type": "string"
          }
        },
        "required": [
          "action"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.rule_change",
      "wire": "receiver_rule_change",
      "tier": "alter",
      "inputSchema": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": [
              "save",
              "delete",
              "move"
            ]
          },
          "rule": {
            "type": "object",
            "description": "Windows routing rule. Matches title or text with contains. It proposes a destination; sending still needs approval.",
            "properties": {
              "id": {
                "type": "string",
                "maxLength": 128
              },
              "name": {
                "type": "string",
                "maxLength": 120
              },
              "sourceId": {
                "type": [
                  "string",
                  "null"
                ],
                "maxLength": 128
              },
              "contains": {
                "type": "string",
                "maxLength": 1000
              },
              "target": {
                "type": "object",
                "properties": {
                  "kind": {
                    "type": "string",
                    "enum": [
                      "session",
                      "chat",
                      "newTask",
                      "hoot",
                      "agent"
                    ]
                  },
                  "id": {
                    "type": [
                      "string",
                      "null"
                    ],
                    "maxLength": 128
                  },
                  "threadKey": {
                    "type": [
                      "string",
                      "null"
                    ],
                    "maxLength": 128
                  }
                },
                "required": [
                  "kind"
                ],
                "additionalProperties": false
              },
              "enabled": {
                "type": "boolean"
              },
              "perHour": {
                "type": "integer",
                "minimum": 1,
                "maximum": 1000
              },
              "conditions": {
                "type": "array", "maxItems": 32,
                "items": {
                  "type": "object", "additionalProperties": false,
                  "properties": {
                    "path": { "type": "string", "minLength": 1, "maxLength": 240 },
                    "operation": { "type": "string", "enum": ["is", "isNot", "contains", "doesNotContain", "startsWith", "matchesPattern", "isPresent", "isMissing", "isOneOf", "isAbove", "isBelow", "isAtLeast"] },
                    "value": { "type": "string", "maxLength": 1000 }
                  },
                  "required": ["path", "operation"]
                }
              },
              "quietStartHour": {
                "type": [
                  "integer",
                  "null"
                ],
                "minimum": 0,
                "maximum": 23
              },
              "quietEndHour": {
                "type": [
                  "integer",
                  "null"
                ],
                "minimum": 0,
                "maximum": 23
              }
            },
            "required": [
              "id",
              "name",
              "contains",
              "target"
            ],
            "additionalProperties": false
          },
          "id": {
            "type": "string"
          },
          "index": {
            "type": "integer",
            "minimum": 0
          }
        },
        "required": [
          "action"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.route",
      "wire": "receiver_route",
      "tier": "act",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string"
          },
          "target": {
            "type": "object",
            "properties": {
              "kind": {
                "type": "string",
                "enum": [
                  "session",
                  "chat",
                  "newTask",
                  "hoot",
                  "agent"
                ]
              },
              "id": {
                "type": [
                  "string",
                  "null"
                ],
                "maxLength": 128
              },
              "threadKey": {
                "type": [
                  "string",
                  "null"
                ],
                "maxLength": 128
              }
            },
            "required": [
              "kind"
            ],
            "additionalProperties": false
          },
          "instruction": {
            "type": "string"
          }
        },
        "required": [
          "id",
          "target"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.replay",
      "wire": "receiver_replay",
      "tier": "act",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string"
          },
          "mode": {
            "type": "string",
            "enum": [
              "retry",
              "replay"
            ]
          }
        },
        "required": [
          "id"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.reply",
      "wire": "receiver_reply",
      "tier": "act",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string"
          },
          "text": {
            "type": "string",
            "maxLength": 8000
          }
        },
        "required": [
          "id",
          "text"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.dismiss",
      "wire": "receiver_dismiss",
      "tier": "act",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string"
          }
        },
        "required": [
          "id"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.intake",
      "wire": "receiver_intake",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": false
      }
    },
    {
      "id": "receiver.intake_change",
      "wire": "receiver_intake_change",
      "tier": "alter",
      "inputSchema": {
        "type": "object",
        "properties": {
          "clipboard": {
            "type": "boolean"
          },
          "browser": {
            "type": "boolean"
          }
        },
        "required": [],
        "additionalProperties": false
      }
    },
    {
      "id": "artifacts.list",
      "wire": "artifacts_list",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {
          "cwd": {
            "type": "string"
          },
          "path": {
            "type": "string"
          },
          "scope": {
            "type": "string",
            "enum": [
              "project",
              "all"
            ]
          },
          "limit": {
            "type": "integer",
            "minimum": 1,
            "maximum": 300
          }
        },
        "required": [
          "cwd"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "artifacts.preview",
      "wire": "artifacts_preview",
      "tier": "read",
      "inputSchema": {
        "type": "object",
        "properties": {
          "cwd": {
            "type": "string"
          },
          "relPath": {
            "type": "string"
          }
        },
        "required": [
          "cwd",
          "relPath"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "artifacts.open",
      "wire": "artifacts_open",
      "tier": "act",
      "inputSchema": {
        "type": "object",
        "properties": {
          "cwd": {
            "type": "string"
          },
          "relPath": {
            "type": "string"
          }
        },
        "required": [
          "cwd",
          "relPath"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "artifacts.send",
      "wire": "artifacts_send",
      "tier": "act",
      "inputSchema": {
        "type": "object",
        "properties": {
          "cwd": {
            "type": "string"
          },
          "relPath": {
            "type": "string"
          },
          "projectId": {
            "type": "string"
          },
          "target": {
            "type": "string"
          }
        },
        "required": [
          "cwd",
          "relPath",
          "target"
        ],
        "additionalProperties": false
      }
    },
    {
      "id": "artifacts.remove",
      "wire": "artifacts_remove",
      "tier": "alter",
      "inputSchema": {
        "type": "object",
        "properties": {
          "cwd": {
            "type": "string"
          },
          "relPath": {
            "type": "string"
          },
          "projectId": {
            "type": "string"
          }
        },
        "required": [
          "cwd",
          "relPath"
        ],
        "additionalProperties": false
      }
    }
  ]
}
""";
}
