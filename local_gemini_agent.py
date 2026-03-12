import os
import sys
import asyncio
from dotenv import load_dotenv
from google import genai
from mcp import ClientSession
from mcp.client.sse import sse_client

load_dotenv()

# We need GEMINI_API_KEY and MCP_SERVER_URL
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not GEMINI_API_KEY:
    print("Error: GEMINI_API_KEY not found in environment.")
    sys.exit(1)

MCP_SERVER_URL = os.getenv("MCP_SERVER_URL")
if not MCP_SERVER_URL:
    print("Error: MCP_SERVER_URL not found in environment.")
    sys.exit(1)

# Initialize Gemini client
client = genai.Client(api_key=GEMINI_API_KEY)


async def run_subagent_loop(prompt: str):
    """The CLI ReAct loop that interacts with the backend Atlassian MCP server."""
    try:
        async with sse_client(MCP_SERVER_URL) as streams:
            async with ClientSession(streams[0], streams[1]) as session:
                await session.initialize()

                # Get available tools from backend MCP
                tools_response = await session.list_tools()

                mcp_tools = [
                    {
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    }
                    for tool in tools_response.tools
                ]

                # Initialize a chat session
                chat = client.chats.create(
                    model="gemini-3.1-flash-lite-preview",
                    config=genai.types.GenerateContentConfig(
                        tools=[{"function_declarations": mcp_tools}]
                        if mcp_tools
                        else None,
                        temperature=0,
                    ),
                )

                response = chat.send_message(prompt)

                while True:
                    if not response.function_calls:
                        break

                    tool_responses = []
                    for fn_call in response.function_calls:
                        print(
                            f"[*] Reasoning: Invoking tool '{fn_call.name}'",
                            file=sys.stderr,
                        )
                        try:
                            # Re-map tool name/args correctly
                            tool_result = await session.call_tool(
                                fn_call.name, arguments=fn_call.args
                            )

                            tool_responses.append(
                                genai.types.Part.from_function_response(
                                    name=fn_call.name,
                                    response={"result": tool_result.content},
                                )
                            )
                        except Exception as e:
                            print(
                                f"[!] Tool Error ('{fn_call.name}'): {e}",
                                file=sys.stderr,
                            )
                            tool_responses.append(
                                genai.types.Part.from_function_response(
                                    name=fn_call.name, response={"error": str(e)}
                                )
                            )

                    # Send tool outputs back as a new turn
                    response = chat.send_message(tool_responses)

                # Output final answer to stdout (read by Cursor)
                if response.text:
                    print(response.text)

    except Exception as e:
        print(f"Subagent System Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print('Usage: uv run local_gemini_agent.py "<prompt>"')
        sys.exit(1)

    asyncio.run(run_subagent_loop(sys.argv[1]))
