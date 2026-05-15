find_package(Sysbuild REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sysbuild LANGUAGES)

# Stamp version.txt into dfu_application.zip after it is built so the
# Omi app can display the version when the user picks a local zip file.
if(TARGET dfu_application_zip)
  file(STRINGS "${APP_DIR}/omi.conf" _conf_lines REGEX "CONFIG_BT_DIS_FW_REV_STR")
  string(REGEX MATCH "\"([^\"]+)\"" _ "${_conf_lines}")
  set(_fw_version "${CMAKE_MATCH_1}")

  if(_fw_version)
    if(NOT PYTHON_EXECUTABLE)
      find_program(PYTHON_EXECUTABLE NAMES python3 python3.12 python REQUIRED)
    endif()

    add_custom_command(
      TARGET dfu_application_zip POST_BUILD
      COMMAND "${PYTHON_EXECUTABLE}"
              "${APP_DIR}/scripts/add_version_to_zip.py"
              "${CMAKE_BINARY_DIR}/dfu_application.zip"
              "${_fw_version}"
      COMMENT "Stamping version ${_fw_version} into dfu_application.zip"
      VERBATIM
    )
  endif()
endif()
