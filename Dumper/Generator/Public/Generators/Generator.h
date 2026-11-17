#pragma once

#include <filesystem>

#include "Unreal/ObjectArray.h"
#include "Managers/DependencyManager.h"
#include "Managers/MemberManager.h"
#include "HashStringTable.h"
#include "DumperDiagnostics.h"


namespace fs = std::filesystem;

void DumpEditorOnlyMetadata(const fs::path& DumperFolder);
void FetchGameNameAndVersion();

template<typename GeneratorType>
concept GeneratorImplementation = requires(GeneratorType t)
{
    /* Require static variables of type */
    GeneratorType::PredefinedMembers;
    requires(std::same_as<decltype(GeneratorType::PredefinedMembers), PredefinedMemberLookupMapType>);

    GeneratorType::MainFolderName;
    requires(std::same_as<decltype(GeneratorType::MainFolderName), std::string>);
    GeneratorType::SubfolderName;
    requires(std::same_as<decltype(GeneratorType::SubfolderName), std::string>);

    GeneratorType::MainFolder;
    requires(std::same_as<decltype(GeneratorType::MainFolder), fs::path>);
    GeneratorType::Subfolder;
    requires(std::same_as<decltype(GeneratorType::Subfolder), fs::path>);
    
    /* Require static functions */
    DumperDiagnostics::Mark("write C++ SDK files");
        GeneratorType::Generate();
        DumperDiagnostics::Mark("generator returned");

    DumperDiagnostics::Mark("init predefined members");
        GeneratorType::InitPredefinedMembers();
    DumperDiagnostics::Mark("init predefined functions");
        GeneratorType::InitPredefinedFunctions();
};

class Generator
{
private:
    friend class GeneratorTest;

private:
    static inline fs::path DumperFolder;
    static inline bool bDumpedGObjects = false;
	static inline bool bDumepdEditorOnlyMetadata = false;

public:
    static void InitEngineCore();
    static void InitInternal();

private:
    static bool SetupDumperFolder();

    static bool SetupFolders(std::string& FolderName, fs::path& OutFolder);
    static bool SetupFolders(std::string& FolderName, fs::path& OutFolder, std::string& SubfolderName, fs::path& OutSubFolder);

public:
    template<GeneratorImplementation GeneratorType>
    static void Generate() 
    { 
        if (DumperFolder.empty())
        {
            DumperDiagnostics::Mark("setup output folder");
            if (!SetupDumperFolder())
                return;

            DumperDiagnostics::Mark("output folder ready");
            if (!bDumpedGObjects)
            {
                bDumpedGObjects = true;
                DumperDiagnostics::Mark("dump object names");
                ObjectArray::DumpObjects(DumperFolder);
                DumperDiagnostics::Mark("object names complete");

                if (Settings::Internal::bUseFProperty)
                    {
                    DumperDiagnostics::Mark("dump properties");
                    ObjectArray::DumpObjectsWithProperties(DumperFolder);
                    DumperDiagnostics::Mark("property dump complete");
                }
            }

            if (!bDumepdEditorOnlyMetadata)
            {
                bDumepdEditorOnlyMetadata = true;
                DumperDiagnostics::Mark("dump editor-only metadata");
                DumpEditorOnlyMetadata(DumperFolder);
                DumperDiagnostics::Mark("editor-only metadata complete");
            }
        }

        DumperDiagnostics::Mark("setup generator folders");
        if (!SetupFolders(GeneratorType::MainFolderName, GeneratorType::MainFolder, GeneratorType::SubfolderName, GeneratorType::Subfolder))
            return;

        GeneratorType::InitPredefinedMembers();
        GeneratorType::InitPredefinedFunctions();

        MemberManager::SetPredefinedMemberLookupPtr(&GeneratorType::PredefinedMembers);

        GeneratorType::Generate();
    };
};
