---
description: Guide for creating high-quality MCP (Model Context Protocol) servers. High-detail workflow.
---

# MCP Server Development Workflow

## 1. Deep Research and Planning

### 1.1 Understand Modern MCP Design

- **API Coverage vs. Workflow Tools**: Balance comprehensive API endpoint coverage with specialized workflow tools.
- **Tool Naming**: Use consistent prefixes (e.g., `github_create_issue`, `github_list_repos`).
- **Context Management**: Design tools that return focused, relevant data. Support filtering/pagination.
- **Error Messages**: Ensure errors guide the agent toward solutions.

### 1.2 Study Protocol Documentation

- Review the [MCP Specification](https://modelcontextprotocol.io/sitemap.xml).
- Key pages: Spec overview, Transport mechanisms, Tool/Resource definitions.

### 1.3 Plan Your Implementation

- **Recommend Stack**:
  - **Language**: TypeScript (preferred) or Python.
  - **Transport**: Stdio for local servers, SSE for remote.
- **Tool Selection**: List endpoints to implement. Define Input/Output schemas (Zod/Pydantic).

## 2. Implementation

### 2.1 Set Up Project Structure

- **TypeScript**:
  - Initialize `package.json` and `tsconfig.json`.
  - Install `@modelcontextprotocol/sdk`.
- **Python**:
  - Initialize `pyproject.toml`.
  - Install `mcp`.

### 2.2 Implement Core Infrastructure

- Create API client with authentication.
- Implement error handling helpers.
- Add pagination support.

### 2.3 Implement Tools

- **Input Schema**: Use Zod (TS) or Pydantic (Py) with clear constraints.
- **Output Schema**: Define structured output where possible.
- **Logic**: Use async/await. handle errors gracefully.
- **Annotations**: Set `isInput` etc.

## 3. Review and Test

### 3.1 Code Quality

- Ensure DRY principle.
- Verify full type coverage.
- Check tool descriptions are concise and informative.

### 3.2 Build and Test

- **TypeScript**: `npm run build`
- **Verify**: Use the MCP Inspector: `npx @modelcontextprotocol/inspector`

### 3.3 Debugging & Common Issues

- **Connection Refused**: Check if the server is running and the port matches.
- **Zod Parse Error**: Your input validation is too strict or the agent is sending malformed data. Relax constraints or improve descriptions.
- **Empty Response**: Ensure your tool returns a JSON object, even if empty (`{}`).
- **Inspector Tips**: Use the "Tools" tab to manually invoke each tool with sample JSON.

## 4. Create Evaluations (Optional)

Create prompt-based evaluations to test if Antigravity can effectively use your MCP server.

1. **Tool Inspection**: List available tools.
2. **Question Generation**: Create 10 complex questions.
3. **Verification**: Solve them to verify answers.

## Reference Files

- [MCP Best Practices](https://modelcontextprotocol.io/docs/best-practices)
