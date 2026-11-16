#ifndef MCP_CSMC_H
#define MCP_CSMC_H
#include <stdint.h>
#include <stddef.h>

// Small original wrapper around the AppleSMC IOKit user-client ABI.
// Never interpret an SMC result as success unless both transport and device succeed.
typedef struct {
    uint32_t type;
    uint32_t size;
    uint8_t bytes[32];
} MCPValue;
int32_t mcp_smc_open(uint32_t *connection);
void mcp_smc_close(uint32_t connection);
int32_t mcp_smc_read(uint32_t connection, const char *key, MCPValue *value);
int32_t mcp_smc_write(uint32_t connection, const char *key, const uint8_t *bytes, uint32_t size);
int32_t mcp_smc_key_at(uint32_t connection, uint32_t index, char *key);
uint32_t mcp_fourcc(const char *text);
#endif
