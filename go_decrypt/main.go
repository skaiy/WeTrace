package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"encoding/hex"
	"os"
	"unsafe"

	"WeTrace/go_decrypt/internal/decrypt/windows"
	"WeTrace/go_decrypt/internal/unlock"
)

// DecryptResult 解密结果
type DecryptResult struct {
	Success bool
	Error   string
}

// ProgressCallback 进度回调函数类型
type ProgressCallback func(current, total int64)

//export ValidateKey
func ValidateKey(dbPath *C.char, hexKey *C.char) C.int {
	goDbPath := C.GoString(dbPath)
	goHexKey := C.GoString(hexKey)

	decryptor := windows.NewV4Decryptor()

	// 读取第一页
	file, err := os.Open(goDbPath)
	if err != nil {
		return 0
	}
	defer file.Close()

	firstPage := make([]byte, decryptor.GetPageSize())
	_, err = file.Read(firstPage)
	if err != nil {
		return 0
	}

	// 解码密钥
	keyBytes := hexToBytes(goHexKey)
	if keyBytes == nil {
		return 0
	}

	// 验证密钥
	if decryptor.Validate(firstPage, keyBytes) {
		return 1
	}
	return 0
}

//export DecryptDatabase
func DecryptDatabase(inputPath *C.char, outputPath *C.char, hexKey *C.char) *C.char {
	goInputPath := C.GoString(inputPath)
	goOutputPath := C.GoString(outputPath)
	goHexKey := C.GoString(hexKey)

	decryptor := windows.NewV4Decryptor()

	// 创建输出文件
	outputFile, err := os.Create(goOutputPath)
	if err != nil {
		return C.CString("failed to create output file: " + err.Error())
	}
	defer outputFile.Close()

	// 执行解密
	ctx := context.Background()
	err = decryptor.Decrypt(ctx, goInputPath, goHexKey, outputFile)
	if err != nil {
		return C.CString(err.Error())
	}

	return nil // nil 表示成功
}

//export ForceUnlockFile
func ForceUnlockFile(filePath *C.char) *C.char {
	goFilePath := C.GoString(filePath)

	err := unlock.ForceUnlockFile(goFilePath)
	if err != nil {
		return C.CString(err.Error())
	}

	return nil // nil 表示成功
}

//export CloseSelfFileHandles
func CloseSelfFileHandles(filePath *C.char) *C.char {
	goFilePath := C.GoString(filePath)

	err := unlock.CloseSelfFileHandles(goFilePath)
	if err != nil {
		return C.CString(err.Error())
	}

	return nil // nil 表示成功
}

//export FreeString
func FreeString(str *C.char) {
	C.free(unsafe.Pointer(str))
}

// hexToBytes 将十六进制字符串转换为字节数组
func hexToBytes(hexStr string) []byte {
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil
	}
	return bytes
}

func main() {
	// 主函数为空，因为这是一个库
}
