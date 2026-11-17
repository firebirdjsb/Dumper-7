#pragma once
// Read-only exception breadcrumbs; does not swallow game exceptions.
#include <Windows.h>
#include <atomic>
#include <cstdio>
#include <cstdint>
#include <iostream>
namespace DumperDiagnostics {
    inline std::atomic<const char*> Stage{"startup"};
    inline std::atomic<unsigned long long> Ordinal{0};
    inline volatile LONG ExceptionCount = 0;
    inline void Mark(const char* Name) {
        Stage.store(Name, std::memory_order_relaxed);
        Ordinal.store(0, std::memory_order_relaxed);
        std::cerr << "[D7-DIAG] " << Name << std::endl;
    }
    inline void SetOrdinal(unsigned long long Number) {
        Ordinal.store(Number, std::memory_order_relaxed);
        if (Number && Number % 4096 == 0)
            std::cerr << "[D7-DIAG] object ordinal " << std::dec << Number << std::hex << std::endl;
    }
    inline LONG CALLBACK ExceptionObserver(EXCEPTION_POINTERS* Info) {
        if (!Info || !Info->ExceptionRecord) return EXCEPTION_CONTINUE_SEARCH;
        DWORD Code = Info->ExceptionRecord->ExceptionCode;
        if (Code != EXCEPTION_ACCESS_VIOLATION && Code != EXCEPTION_ILLEGAL_INSTRUCTION &&
            Code != EXCEPTION_STACK_OVERFLOW && Code != EXCEPTION_IN_PAGE_ERROR)
            return EXCEPTION_CONTINUE_SEARCH;
        if (InterlockedIncrement(&ExceptionCount) > 16) return EXCEPTION_CONTINUE_SEARCH;
        const void* Fault = Info->ExceptionRecord->ExceptionAddress;
        HMODULE Module = nullptr;
        char ModulePath[MAX_PATH]{};
        if (Fault && GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, reinterpret_cast<LPCSTR>(Fault), &Module))
            GetModuleFileNameA(Module, ModulePath, MAX_PATH);
        uintptr_t RVA = Module ? reinterpret_cast<uintptr_t>(Fault) - reinterpret_cast<uintptr_t>(Module) : 0;
        const void* BadPtr = Info->ExceptionRecord->NumberParameters >= 2
            ? reinterpret_cast<const void*>(Info->ExceptionRecord->ExceptionInformation[1]) : nullptr;
        char Message[1400]{};
        int Len = std::snprintf(Message, sizeof(Message),
            "[D7-DIAG] exception=0x%08lX stage=%s ordinal=%llu fault=%p module=%s rva=0x%llX badptr=%p\r\n",
            static_cast<unsigned long>(Code), Stage.load(std::memory_order_relaxed),
            Ordinal.load(std::memory_order_relaxed), Fault,
            ModulePath[0] ? ModulePath : "<unknown>", static_cast<unsigned long long>(RVA), BadPtr);
        if (Len > 0) {
            CreateDirectoryA("C:\\Dumper-7", nullptr);
            HANDLE File = CreateFileA("C:\\Dumper-7\\Dumper7-CrashTrace.log", FILE_APPEND_DATA,
                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (File != INVALID_HANDLE_VALUE) {
                DWORD Written = 0;
                DWORD Bytes = static_cast<DWORD>(Len < static_cast<int>(sizeof(Message)) ? Len : sizeof(Message) - 1);
                WriteFile(File, Message, Bytes, &Written, nullptr);
                CloseHandle(File);
            }
        }
        return EXCEPTION_CONTINUE_SEARCH;
    }
    inline void Install() { AddVectoredExceptionHandler(1, ExceptionObserver); }
}
