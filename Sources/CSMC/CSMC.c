#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

// 80-byte AppleSMC user-client message layout (undocumented platform ABI).
// This file does not include or depend upon third-party SMC implementations.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key;
    Version version;
    Limits limits;
    KeyInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} Message;
_Static_assert(sizeof(Message) == 80, "AppleSMC message ABI must be 80 bytes");

uint32_t mcp_fourcc(const char *text) {
    if (!text || strlen(text) != 4) return 0;
    return ((uint32_t)(uint8_t)text[0] << 24) | ((uint32_t)(uint8_t)text[1] << 16)
         | ((uint32_t)(uint8_t)text[2] << 8) | (uint8_t)text[3];
}
static int32_t invoke(uint32_t connection, Message *input, Message *output) {
    size_t size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    if (result != KERN_SUCCESS) return result;
    if (size != sizeof(*output)) return kIOReturnBadArgument;
    if (output->result) return (int32_t)(0xE0000000u | output->result);
    return 0;
}
int32_t mcp_smc_open(uint32_t *connection) {
    if (!connection) return kIOReturnBadArgument;
    *connection = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}
void mcp_smc_close(uint32_t connection) { if (connection) IOServiceClose(connection); }
static int32_t info_for(uint32_t connection, const char *key, KeyInfo *info) {
    uint32_t code = mcp_fourcc(key);
    if (!code) return kIOReturnBadArgument;
    Message input = {0}, output = {0};
    input.key = code;
    input.command = 9;
    int32_t result = invoke(connection, &input, &output);
    if (result) return result;
    if (output.info.size == 0 || output.info.size > 32) return kIOReturnBadArgument;
    *info = output.info;
    return 0;
}
int32_t mcp_smc_read(uint32_t connection, const char *key, MCPValue *value) {
    if (!value) return kIOReturnBadArgument;
    memset(value, 0, sizeof(*value));
    KeyInfo info;
    int32_t result = info_for(connection, key, &info);
    if (result) return result;
    Message input = {0}, output = {0};
    input.key = mcp_fourcc(key);
    input.info.size = info.size;
    input.command = 5;
    result = invoke(connection, &input, &output);
    if (result) return result;
    value->type = info.type;
    value->size = info.size;
    memcpy(value->bytes, output.bytes, info.size);
    return 0;
}
int32_t mcp_smc_write(uint32_t connection, const char *key, const uint8_t *bytes, uint32_t size) {
    if (!bytes || !size || size > 32) return kIOReturnBadArgument;
    KeyInfo info;
    int32_t result = info_for(connection, key, &info);
    if (result) return result;
    if (size != info.size) return kIOReturnBadArgument;
    Message input = {0}, output = {0};
    input.key = mcp_fourcc(key);
    input.info.size = size;
    input.command = 6;
    memcpy(input.bytes, bytes, size);
    return invoke(connection, &input, &output);
}
int32_t mcp_smc_key_at(uint32_t connection, uint32_t index, char *key) {
    if (!key) return kIOReturnBadArgument;
    Message input = {0}, output = {0};
    input.command = 8;
    input.index = index;
    int32_t result = invoke(connection, &input, &output);
    if (result) return result;
    for (int i = 0; i < 4; i++) key[i] = (char)((output.key >> (24 - 8*i)) & 255);
    key[4] = 0;
    return 0;
}
