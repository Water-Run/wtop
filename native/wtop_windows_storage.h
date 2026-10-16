/* Read-only storage queries. Called only by the isolated health reader.
 * The numeric property IDs keep the XP SDK a valid build target. */
#ifndef WTOP_WINDOWS_STORAGE_H
#define WTOP_WINDOWS_STORAGE_H

#define WTOP_STORAGE_TEMPERATURE_BYTES 536u /* Header + 32 sensor entries. */
typedef struct {
    DWORD temperature_error, nvme_error, ata_error;
    DWORD temperature_size, nvme_size, ata_size;
    BYTE temperature[WTOP_STORAGE_TEMPERATURE_BYTES];
    BYTE nvme[512], ata[512];
    int requested, deep, skipped;
} wtop_storage_reading;

static void wtop_storage_temperature(HANDLE drive, wtop_storage_reading *reading) {
    STORAGE_PROPERTY_QUERY query;
    DWORD returned = 0;
    memset(&query, 0, sizeof(query));
    query.PropertyId = (STORAGE_PROPERTY_ID)52;
    if (!DeviceIoControl(drive, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query),
            reading->temperature, sizeof(reading->temperature), &returned, NULL)) {
        reading->temperature_error = GetLastError();
    } else if (returned > sizeof(reading->temperature) || returned < 24) {
        reading->temperature_error = ERROR_INVALID_DATA;
    } else reading->temperature_size = returned;
}

static void wtop_storage_nvme(HANDLE drive, wtop_storage_reading *reading) {
    /* STORAGE_PROPERTY_QUERY(8) + protocol data(40) + health log(512). */
    union { DWORD aligned[140]; BYTE bytes[560]; } buffer;
    DWORD returned = 0, *fields = buffer.aligned;
    memset(&buffer, 0, sizeof(buffer));
    fields[0] = 50; /* StorageDeviceProtocolSpecificProperty */
    fields[2] = 3;  /* ProtocolTypeNvme */
    fields[3] = 2;  /* NVMeDataTypeLogPage */
    fields[4] = 2;  /* SMART / Health Information */
    fields[6] = 40;
    fields[7] = 512;
    if (!DeviceIoControl(drive, IOCTL_STORAGE_QUERY_PROPERTY, &buffer, sizeof(buffer),
            &buffer, sizeof(buffer), &returned, NULL)) {
        reading->nvme_error = GetLastError(); return;
    }
    if (returned < 48 || returned > sizeof(buffer) || fields[0] != 48 || fields[1] != 48
            || fields[2] != 3 || fields[3] != 2 || fields[6] < 40
            || fields[6] > returned - 8 || fields[7] < 512
            || fields[7] > returned - 8 - fields[6]) {
        reading->nvme_error = ERROR_INVALID_DATA; return;
    }
    memcpy(reading->nvme, buffer.bytes + 8 + fields[6], 512);
    reading->nvme_size = 512;
}

static void wtop_storage_ata(HANDLE drive, wtop_storage_reading *reading, DWORD number) {
    GETVERSIONINPARAMS version;
    SENDCMDINPARAMS input;
    union { SENDCMDOUTPARAMS aligned; BYTE bytes[528]; } output;
    DWORD returned = 0;
    memset(&version, 0, sizeof(version));
    if (!DeviceIoControl(drive, SMART_GET_VERSION, NULL, 0, &version, sizeof(version),
            &returned, NULL)) {
        reading->ata_error = GetLastError(); return;
    }
    if (returned != sizeof(version) || !(version.fCapabilities & 4)) {
        reading->ata_error = ERROR_NOT_SUPPORTED; return;
    }
    if (number > 255) { reading->ata_error = ERROR_NOT_SUPPORTED; return; }
    memset(&input, 0, sizeof(input)); memset(&output, 0, sizeof(output));
    input.cBufferSize = 512;
    input.irDriveRegs.bFeaturesReg = 0xd0; /* SMART READ DATA only. */
    input.irDriveRegs.bSectorCountReg = 1;
    input.irDriveRegs.bSectorNumberReg = 1;
    input.irDriveRegs.bCylLowReg = 0x4f;
    input.irDriveRegs.bCylHighReg = 0xc2;
    input.irDriveRegs.bDriveHeadReg = (BYTE)(0xa0 | ((number & 1) << 4));
    input.irDriveRegs.bCommandReg = 0xb0;
    input.bDriveNumber = (BYTE)number;
    if (!DeviceIoControl(drive, SMART_RCV_DRIVE_DATA, &input,
            (DWORD)offsetof(SENDCMDINPARAMS, bBuffer), &output, sizeof(output), &returned, NULL)) {
        reading->ata_error = GetLastError(); return;
    }
    if (returned < offsetof(SENDCMDOUTPARAMS, bBuffer) + 512 || returned > sizeof(output)
            || output.aligned.cBufferSize < 512 || output.aligned.DriverStatus.bDriverError) {
        reading->ata_error = ERROR_INVALID_DATA; return;
    }
    memcpy(reading->ata, output.aligned.bBuffer, 512); reading->ata_size = 512;
}

static void wtop_storage_read(HANDLE drive, wtop_storage_reading *reading, int bus,
    DWORD number, int deep) {
    memset(reading, 0, sizeof(*reading)); reading->deep = deep;
    /* Default sampling uses standard NVMe queries; ATA and bridges are explicit-only. */
    if (bus != 17 && !deep) { reading->skipped = 1; return; }
    reading->requested = 1;
    wtop_storage_temperature(drive, reading);
    if (bus == 17) wtop_storage_nvme(drive, reading);
    else if (bus == 3 || bus == 11 || bus == 2) wtop_storage_ata(drive, reading, number);
    else reading->ata_error = ERROR_NOT_SUPPORTED;
}

static void wtop_storage_push(lua_State *L, const wtop_storage_reading *reading) {
    lua_createtable(L, 0, 9);
    lua_pushboolean(L, reading->deep); lua_setfield(L, -2, "deep");
    lua_pushboolean(L, reading->skipped); lua_setfield(L, -2, "skipped");
    if (reading->temperature_size) {
        lua_pushlstring(L, (const char *)reading->temperature, reading->temperature_size);
        lua_setfield(L, -2, "temperature_data");
    }
    if (reading->nvme_size) {
        lua_pushlstring(L, (const char *)reading->nvme, reading->nvme_size);
        lua_setfield(L, -2, "nvme_data");
    }
    if (reading->ata_size) {
        lua_pushlstring(L, (const char *)reading->ata, reading->ata_size);
        lua_setfield(L, -2, "ata_data");
    }
    lua_pushinteger(L, reading->temperature_error); lua_setfield(L, -2, "temperature_error");
    lua_pushinteger(L, reading->nvme_error); lua_setfield(L, -2, "nvme_error");
    lua_pushinteger(L, reading->ata_error); lua_setfield(L, -2, "ata_error");
}
#endif
