//
//  WBBladesScanManager+CrashSymbol.m
//  WBBlades
//
//  Created by 邓竹立 on 2019/12/30.
//  Copyright © 2019 邓竹立. All rights reserved.
//

#import "WBBladesScanManager+CrashSymbol.h"
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/vm_map.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <mach-o/nlist.h>

#import "WBBladesTool.h"
#import "WBBladesDefines.h"
#import "WBBladesCMD.h"

@implementation WBBladesScanManager (CrashSymbol)

#pragma mark symbolize
+ (NSDictionary *)symbolizeWithMachOFile:(NSData *)fileData crashOffsets:(NSArray *)crashAddresses {

    mach_header_64 mhHeader;
    [fileData getBytes:&mhHeader range:NSMakeRange(0, sizeof(mach_header_64))];
    
    section_64 classList = {0};
    section_64 nlcatList = {0};
    section_64 swift5Types = {0};
    symtab_command symTabCommand = {0};
    segment_command_64 linkEdit = {0};
    
    unsigned long long currentLcLocation = sizeof(mach_header_64);
    for (int i = 0; i < mhHeader.ncmds; i++) {
        load_command* cmd = (load_command *)malloc(sizeof(load_command));
        [fileData getBytes:cmd range:NSMakeRange(currentLcLocation, sizeof(load_command))];
        
        if (cmd->cmd == LC_SEGMENT_64) {//LC_SEGMENT_64:(section header....)
            segment_command_64 segmentCommand;
            [fileData getBytes:&segmentCommand range:NSMakeRange(currentLcLocation, sizeof(segment_command_64))];
            NSString *segName = [NSString stringWithFormat:@"%s",segmentCommand.segname];
            
            //遍历查找classlist
            if ([segName isEqualToString:SEGMENT_DATA] ||
                [segName isEqualToString:SEGMENT_DATA_CONST]) {
                //遍历所有的section header
                unsigned long long currentSecLocation = currentLcLocation + sizeof(segment_command_64);
                for (int j = 0; j < segmentCommand.nsects; j++) {
                    section_64 sectionHeader;
                    [fileData getBytes:&sectionHeader range:NSMakeRange(currentSecLocation, sizeof(section_64))];
                    NSString *secName = [[NSString alloc] initWithUTF8String:sectionHeader.sectname];
                    if ([secName isEqualToString:DATA_CLASSLIST_SECTION] ||
                        [secName isEqualToString:CONST_DATA_CLASSLIST_SECTION]) {
                        classList = sectionHeader;
                    }
                     //note ncatlist
                    if ([secName isEqualToString:DATA_NCATLIST_SECTION] ||
                        [secName isEqualToString:CONST_DATA_NCATLIST_SECTION]) {
                        nlcatList = sectionHeader;
                    }
                    currentSecLocation += sizeof(section_64);
                }
            }else if([segName isEqualToString:SEGMENT_TEXT]){
                unsigned long long currentSecLocation = currentLcLocation + sizeof(segment_command_64);
                for (int j = 0; j < segmentCommand.nsects; j++) {
                    
                    section_64 sectionHeader;
                    [fileData getBytes:&sectionHeader range:NSMakeRange(currentSecLocation, sizeof(section_64))];
                    NSString *secName = [[NSString alloc] initWithUTF8String:sectionHeader.sectname];
                    if ([secName isEqualToString:TEXT_SWIFT5_TYPES]) {
                        swift5Types = sectionHeader;
                    }
                    currentSecLocation += sizeof(section_64);
                }
            }else if([segName isEqualToString:SEGMENT_LINKEDIT]){
                linkEdit = segmentCommand;
            }
        }else if(cmd->cmd == LC_SYMTAB){
            [fileData getBytes:&symTabCommand range:NSMakeRange(currentLcLocation, sizeof(symtab_command))];
            
        }
        currentLcLocation += cmd->cmdsize;
        free(cmd);
    }
    
    if ([self hasDWARF:symTabCommand fileData:fileData]) {//有Symbol Table
        uintptr_t linkBase = linkEdit.vmaddr - linkEdit.fileoff;
        NSDictionary *result = [self scanCrashSymbolResultWithSymbolTable:symTabCommand linkBase:linkBase fileData:fileData crashOffsets:crashAddresses];
        return result;
    }
    
    NSDictionary *crashSymbolRst = [self scanCrashSymbolResult:classList catlist:nlcatList swift5Type:swift5Types fileData:fileData crashOffsets:crashAddresses];
    
    NSData *resultsData = [NSJSONSerialization dataWithJSONObject:crashSymbolRst options:NSJSONWritingPrettyPrinted error:nil];
    NSString *resultsJson = [[NSString alloc] initWithData:resultsData encoding:NSUTF8StringEncoding];
    [resultsJson writeToFile:@"/dev/stdout" atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return crashSymbolRst;
}

+ (NSDictionary *)scanCrashSymbolResultWithSymbolTable:(symtab_command)symTabCommand linkBase:(uintptr_t)linkBase fileData:(NSData *)fileData crashOffsets:(NSArray *)crashAddresses{
    NSRange range = NSMakeRange(8, 0);
    range = NSMakeRange(symTabCommand.symoff, 0);
    NSDictionary *symbols = [self scanExcutableSymbolTab:fileData range:range commandCount:symTabCommand.nsyms];
    
    NSMutableDictionary *crashSymbolRst = [NSMutableDictionary dictionary];
    if (symbols && symbols.allKeys.count > 0) {
        //针对崩溃堆栈偏移地址进行排序
        NSArray *crashAddress = [crashAddresses sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
            if ([obj1 integerValue] > [obj2 integerValue]) {
                 return NSOrderedDescending;
            }else if ([obj1 integerValue] == [obj2 integerValue]){
                return NSOrderedSame;
            }
            return NSOrderedAscending;
        }];
        
        NSInteger index = 0;
        NSString *addr = crashAddress[index];
        
        //针对symbol做排序
        NSArray *orderedSymbols = [symbols.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
            if ([obj1 integerValue] > [obj2 integerValue]) {
                 return NSOrderedDescending;
            }else if ([obj1 integerValue] == [obj2 integerValue]){
                return NSOrderedSame;
            }
            return NSOrderedAscending;
        }];
        
        for (NSInteger j = 1; j<orderedSymbols.count; j++) {
            NSString *symbolKey = orderedSymbols[j];
            
            if ([symbolKey integerValue] > linkBase && (([symbolKey integerValue] - linkBase) > [addr integerValue])) {
                NSString *lastSymbolKey = orderedSymbols[j-1];
                
                uintptr_t stringOffset = symTabCommand.stroff + [symbols[lastSymbolKey] integerValue];
                uint8_t *buffer = (uint8_t *)malloc(CLASSNAME_MAX_LEN + 1); buffer[CLASSNAME_MAX_LEN] = '\0';
                [fileData getBytes:buffer range:NSMakeRange(stringOffset, CLASSNAME_MAX_LEN)];
                NSString *symbolName = NSSTRING(buffer);

                NSString *orgName = [WBBladesTool getDemangleName:symbolName];
                NSMutableDictionary *dic = @{IMP_KEY:lastSymbolKey,SYMBOL_KEY:[NSString stringWithFormat:@"%@",orgName]}.mutableCopy;
                [crashSymbolRst setObject:dic forKey:addr];
                if (index < crashAddress.count - 1) {
                    index++;
                    addr = crashAddress[index];
                }else{
                    break;
                }
            }
        }
        
    }
    
    return crashSymbolRst;
}

+ (NSDictionary *)scanCrashSymbolResult:(section_64)classList catlist:(section_64)ncatlist swift5Type:(section_64)swift5Types fileData:(NSData*)fileData crashOffsets:(NSArray *)crashAddress{
    unsigned long long max = [fileData length];
    unsigned long long vm = classList.addr - classList.offset;
    
    static NSMutableDictionary *crashSymbolRst = @{}.mutableCopy;

    //获取所有类classlist
    NSRange range = NSMakeRange(classList.offset, 0);
    for (int i = 0; i < classList.size / 8 ; i++) {
        @autoreleasepool {
            unsigned long long classAddress;
            NSData *data = [WBBladesTool readBytes:range length:8 fromFile:fileData];
            [data getBytes:&classAddress range:NSMakeRange(0, 8)];
            unsigned long long classOffset = classAddress - vm;
            
            class64 targetClass = {0};
            NSRange targetClassRange = NSMakeRange(classOffset, 0);
            data = [WBBladesTool readBytes:targetClassRange length:sizeof(class64) fromFile:fileData];
            [data getBytes:&targetClass length:sizeof(class64)];
            
            class64Info targetClassInfo = {0};
            unsigned long long targetClassInfoOffset = targetClass.data - vm;
            targetClassInfoOffset = (targetClassInfoOffset / 8) * 8;
            NSRange targetClassInfoRange = NSMakeRange(targetClassInfoOffset, 0);
            data = [WBBladesTool readBytes:targetClassInfoRange length:sizeof(class64Info) fromFile:fileData];
            [data getBytes:&targetClassInfo length:sizeof(class64Info)];
            unsigned long long classNameOffset = [WBBladesTool getOffsetFromVmAddress:targetClassInfo.name fileData:fileData];//targetClassInfo.name - vm;
            
            class64 metaClass = {0};
            NSRange metaClassRange = NSMakeRange(targetClass.isa - vm, 0);
            data = [WBBladesTool readBytes:metaClassRange length:sizeof(class64) fromFile:fileData];
            [data getBytes:&metaClass length:sizeof(class64)];
            
            class64Info metaClassInfo = {0};
            unsigned long long metaClassInfoOffset = metaClass.data - vm;
            metaClassInfoOffset = (metaClassInfoOffset / 8) * 8;
            NSRange metaClassInfoRange = NSMakeRange(metaClassInfoOffset, 0);
            data = [WBBladesTool readBytes:metaClassInfoRange length:sizeof(class64Info) fromFile:fileData];
            [data getBytes:&metaClassInfo length:sizeof(class64Info)];
            
            unsigned long long methodListOffset = targetClassInfo.baseMethods - vm;
            unsigned long long classMethodListOffset = metaClassInfo.baseMethods - vm;
            
            //类名最大50字节
            uint8_t * buffer = (uint8_t *)malloc(CLASSNAME_MAX_LEN + 1); buffer[CLASSNAME_MAX_LEN] = '\0';
            [fileData getBytes:buffer range:NSMakeRange(classNameOffset, CLASSNAME_MAX_LEN)];
            NSString * className = NSSTRING(buffer);
            free(buffer);

            //遍历每个class的method (实例方法)
            if (methodListOffset > 0 && methodListOffset < max) {
                NSDictionary *methodRst = [self scanMethodListResult:methodListOffset
                                                           className:className
                                                                  vm:vm
                                                            fileData:fileData
                                                        crashAddress:crashAddress];
                [crashSymbolRst addEntriesFromDictionary:methodRst];
            }
            //类方法
            if (classMethodListOffset > 0 && classMethodListOffset < max) {
                NSDictionary *classMethodRst = [self scanClassMethodListResult:classMethodListOffset
                                                                     className:className
                                                                            vm:vm
                                                                      fileData:fileData
                                                                  crashAddress:crashAddress];
                [crashSymbolRst addEntriesFromDictionary:classMethodRst];
            }
        }
    }

    range = NSMakeRange(ncatlist.offset, 0);
    for (int i = 0; i < ncatlist.size / 8 ; i++) {
       @autoreleasepool {
           unsigned long long catAddress;
           NSData *data = [WBBladesTool readBytes:range length:8 fromFile:fileData];
           [data getBytes:&catAddress range:NSMakeRange(0, 8)];
           unsigned long long catOffset = catAddress - vm;
           
           category64 targetCategory = {0};
           NSRange targetCategoryRange = NSMakeRange(catOffset, 0);
           data = [WBBladesTool readBytes:targetCategoryRange length:sizeof(category64) fromFile:fileData];
           [data getBytes:&targetCategory length:sizeof(category64)];
           
           unsigned long long categoryNameOffset = [WBBladesTool getOffsetFromVmAddress:targetCategory.name fileData:fileData];//targetCategory.name - vm;
           
           //category name 50 bytes maximum
           uint8_t *buffer = (uint8_t *)malloc(CLASSNAME_MAX_LEN + 1); buffer[CLASSNAME_MAX_LEN] = '\0';
           [fileData getBytes:buffer range:NSMakeRange(categoryNameOffset, CLASSNAME_MAX_LEN)];
           NSString *catName = NSSTRING(buffer);
           
           //dylib class category
           NSString *className = @"";
           if (targetCategory.cls == 0) {
               NSDictionary *bindInfo = [WBBladesTool dynamicBindingInfoFromFile:fileData];
               unsigned long long classBindAddress = catAddress + 8;
               className = bindInfo[@(classBindAddress)];
               className = [NSString stringWithFormat:@"%@(%@)",className,catName];
           }else{
               class64 targetClass;
               [fileData getBytes:&targetClass range:NSMakeRange(targetCategory.cls - vm,sizeof(class64))];
               
               class64Info targetClassInfo = {0};
               unsigned long long targetClassInfoOffset = targetClass.data - vm;
               targetClassInfoOffset = (targetClassInfoOffset / 8) * 8;
               NSRange targetClassInfoRange = NSMakeRange(targetClassInfoOffset, 0);
               data = [WBBladesTool readBytes:targetClassInfoRange length:sizeof(class64Info) fromFile:fileData];
               [data getBytes:&targetClassInfo length:sizeof(class64Info)];
               unsigned long long classNameOffset = [WBBladesTool getOffsetFromVmAddress:targetClassInfo.name fileData:fileData];//targetClassInfo.name - vm;
               
               //class name 50 bytes maximum
               buffer[CLASSNAME_MAX_LEN] = '\0';
               [fileData getBytes:buffer range:NSMakeRange(classNameOffset, CLASSNAME_MAX_LEN)];
               className = NSSTRING(buffer);
               className = [className stringByAppendingFormat:@"%@(%@)",className,catName];
           }
           unsigned long long methodListOffset = targetCategory.instanceMethods - vm;
           unsigned long long classMethodListOffset = targetCategory.classMethods - vm;

           //遍历每个class的method (实例方法)
           if (methodListOffset > 0 && methodListOffset < max) {
               NSDictionary *methodRst = [self scanMethodListResult:methodListOffset
                                                          className:className
                                                                 vm:vm
                                                           fileData:fileData
                                                       crashAddress:crashAddress];
               [crashSymbolRst addEntriesFromDictionary:methodRst];
           }
           //类方法
           if (classMethodListOffset > 0 && classMethodListOffset < max) {
               NSDictionary *classMethodRst = [self scanClassMethodListResult:classMethodListOffset
                                                                    className:className
                                                                           vm:vm
                                                                     fileData:fileData
                                                                 crashAddress:crashAddress];
               [crashSymbolRst addEntriesFromDictionary:classMethodRst];
           }
       }
    }
    
    //Scan Swift
    range = NSMakeRange(swift5Types.offset, 0);
    NSUInteger location = 0;
    uintptr_t linkBase = swift5Types.addr - swift5Types.offset;
    for (int i = 0; i < swift5Types.size / 4 ; i++) {
        uintptr_t offset = swift5Types.addr + location - linkBase;
        
        range = NSMakeRange(offset, 0);
        uintptr_t content = 0;
        NSData *data = [WBBladesTool readBytes:range length:4 fromFile:fileData];
        [data getBytes:&content range:NSMakeRange(0, 4)];
        
        uintptr_t typeOffset = content + offset - linkBase;
        
        SwiftType swiftType = {0};
        range = NSMakeRange(typeOffset, 0);
        data = [WBBladesTool readBytes:range length:sizeof(SwiftType) fromFile:fileData];
        [data getBytes:&swiftType range:NSMakeRange(0, sizeof(SwiftType))];
    
        SwiftKind kindType = [WBBladesTool getSwiftType:swiftType];
        if (kindType == SwiftKindClass) {
            NSDictionary *methodDic = [self scanSwiftClassMethodSymbol:typeOffset
                                                             swiftType:swiftType
                                                                    vm:vm
                                                              fileData:fileData
                                                          crashAddress:crashAddress];
            [crashSymbolRst addEntriesFromDictionary:methodDic];
        }else if(kindType == SwiftKindStruct){
            
        }else if(kindType == SwiftKindEnum){
            
        }
        location += sizeof(uint32_t);
    }
    
    return crashSymbolRst.copy;
}

+ (NSDictionary *)scanMethodListResult:(unsigned long long)methodListOffset
                            className:(NSString*)className
                                   vm:(unsigned long long)vm
                             fileData:(NSData*)fileData
                         crashAddress:(NSArray *)crashAddress{
    
    unsigned long long max = [fileData length];
    method64_list_t methodList;
    
    NSRange methodRange = NSMakeRange(methodListOffset, 0);
    NSData* data = [WBBladesTool readBytes:methodRange length:sizeof(method64_list_t) fromFile:fileData];
    [data getBytes:&methodList length:sizeof(method64_list_t)];
    
    NSMutableDictionary *crashSymbolRst = [NSMutableDictionary dictionary];
    for (int j = 0; j<methodList.count; j++) {
        
        //获取方法名
        methodRange = NSMakeRange(methodListOffset + sizeof(method64_list_t) + sizeof(method64_t) * j, 0);
        data = [WBBladesTool readBytes:methodRange length:sizeof(method64_t) fromFile:fileData];
        
        method64_t method;
        [data getBytes:&method length:sizeof(method64_t)];
        unsigned long long methodNameOffset = [WBBladesTool getOffsetFromVmAddress:method.name fileData:fileData];//method.name;
                
        //方法名最大150字节
        uint8_t * buffer = (uint8_t *)malloc(METHODNAME_MAX_LEN + 1); buffer[METHODNAME_MAX_LEN] = '\0';
        if (methodNameOffset > 0 && methodNameOffset < max) {
            [fileData getBytes:buffer range:NSMakeRange(methodNameOffset,METHODNAME_MAX_LEN)];
            NSString * methodName = NSSTRING(buffer);
            
            unsigned long long imp = method.imp;
            NSLog(@"遍历 -[%@ %@]",className,methodName);
            [crashAddress enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                unsigned long long crash = [(NSString *)obj longLongValue];
                if ([self scanFuncBinaryCode:crash begin:imp vm:vm fileData:fileData]) {
                    NSString *key = [NSString stringWithFormat:@"%lld",crash];
                    if (!crashSymbolRst[key] || [crashSymbolRst[key][IMP_KEY] longLongValue] < imp) {
                        NSMutableDictionary *dic = @{IMP_KEY:@(imp),SYMBOL_KEY:[NSString stringWithFormat:@"-[%@ %@]",className,methodName]}.mutableCopy;
                        [crashSymbolRst setObject:dic forKey:key];
                    }
                }
            }];
        }
        free(buffer);
    }
    return crashSymbolRst.copy;
}

+ (NSDictionary *)scanClassMethodListResult:(unsigned long long)classMethodListOffset
                                  className:(NSString*)className
                                         vm:(unsigned long long)vm
                                   fileData:(NSData*)fileData
                               crashAddress:(NSArray *)crashAddress{
    unsigned long long max = [fileData length];
    method64_list_t methodList;
    
    NSRange methodRange = NSMakeRange(classMethodListOffset, 0);
    NSData* data = [WBBladesTool readBytes:methodRange length:sizeof(method64_list_t) fromFile:fileData];
    [data getBytes:&methodList length:sizeof(method64_list_t)];
    
    NSMutableDictionary *crashSymbolRst = [NSMutableDictionary dictionary];
    for (int j = 0; j<methodList.count; j++) {
        
        //获取方法名
        method64_t method;
        methodRange = NSMakeRange(classMethodListOffset+sizeof(method64_list_t) + sizeof(method64_t) * j, 0);
        data = [WBBladesTool readBytes:methodRange length:sizeof(method64_t) fromFile:fileData];
        
        [data getBytes:&method length:sizeof(method64_t)];
        unsigned long long methodNameOffset = [WBBladesTool getOffsetFromVmAddress:method.name fileData:fileData];//method.name - vm - 0x4c000;
        
        //方法名最大150字节
        uint8_t * buffer = (uint8_t *)malloc(METHODNAME_MAX_LEN + 1); buffer[METHODNAME_MAX_LEN] = '\0';
        if (methodNameOffset > 0 && methodNameOffset < max) {
            [fileData getBytes:buffer range:NSMakeRange(methodNameOffset,METHODNAME_MAX_LEN)];
            NSString * methodName = NSSTRING(buffer);
            unsigned long long imp = method.imp;
            NSLog(@"遍历 +[%@ %@]",className,methodName);
            [crashAddress enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                unsigned long long crash = [(NSString *)obj longLongValue];
                if ([self scanFuncBinaryCode:crash begin:imp vm:vm fileData:fileData] ) {
                    NSString *key = [NSString stringWithFormat:@"%lld",crash];
                    if (!crashSymbolRst[key] || [crashSymbolRst[key][IMP_KEY] longLongValue] < imp) {
                        NSMutableDictionary *dic = @{IMP_KEY:@(imp),SYMBOL_KEY:[NSString stringWithFormat:@"+[%@ %@]",className,methodName]}.mutableCopy;
                        [crashSymbolRst setObject:dic forKey:key];
                    }
                }
            }];
        }
        free(buffer);
    }
    return crashSymbolRst.copy;
}

+ (BOOL)scanFuncBinaryCode:(unsigned long long)target  begin:(unsigned long long)begin  vm:(unsigned long long )vm fileData:(NSData*)fileData {
    if (begin > target + vm) {
        return NO;
    }
    
    unsigned int asmCode = 0;
    do {
        [fileData getBytes:&asmCode range:NSMakeRange(begin - vm, 4)];
        if (begin == target + vm) {
            return YES;
        }
        begin += 4;
    } while (asmCode != RET);
    return NO;
}


+ (NSDictionary *)scanSwiftClassMethodSymbol:(uintptr_t)typeOffset swiftType:(SwiftType)swiftType vm:(uintptr_t)vm fileData:(NSData *)fileData crashAddress:(NSArray *)crashAddress{
    NSMutableDictionary *crashSymbolRst = [NSMutableDictionary dictionary];
    
    NSString *className = [WBBladesTool getSwiftTypeNameWithSwiftType:swiftType Offset:typeOffset fileData:fileData];
    
    SwiftClassType classType = {0};
    NSRange range = NSMakeRange(typeOffset, 0);
    NSData *data = [WBBladesTool readBytes:range length:sizeof(SwiftClassType) fromFile:fileData];
    [data getBytes:&classType length:sizeof(SwiftClassType)];
    
    uintptr_t fieldOffset = typeOffset + 4*4 + classType.FieldDescriptor;
    FieldDescriptor fieldDes = {0};
    range = NSMakeRange(fieldOffset, 0);
    data = [WBBladesTool readBytes:range length:sizeof(FieldDescriptor) fromFile:fileData];
    [data getBytes:&fieldDes length:sizeof(FieldDescriptor)];
    
    NSInteger memCount = fieldDes.NumFields;//先获取属性有几个
    uintptr_t memberOffset = fieldOffset + 4*4;
    
    uintptr_t methodLocation = typeOffset + sizeof(SwiftClassType);
    UInt32 methodNum = classType.NumMethods;
    NSMutableArray *methodArray = [NSMutableArray array];
    FieldRecord record = {0};
    NSInteger memSqu = 0;

    if ((swiftType.Flag&0x80000000) == 0x80000000) {//有VTable
        for (int j = 0; j < methodNum; j++) {
            [methodArray addObject:@(methodLocation)];
            SwiftMethod method = {0};
            range = NSMakeRange(methodLocation, 0);
            data = [WBBladesTool readBytes:range length:sizeof(SwiftMethod) fromFile:fileData];
            [data getBytes:&method length:sizeof(SwiftClassType)];
            
            SwiftMethodKind methodKind = [WBBladesTool getSwiftMethodKind:method];
            if (methodKind == SwiftMethodKindGetter && memSqu < memCount) {
                range = NSMakeRange(memberOffset + memSqu*sizeof(FieldRecord), 0);
                data = [WBBladesTool readBytes:range length:sizeof(FieldRecord) fromFile:fileData];
                [data getBytes:&record length:sizeof(FieldRecord)];
                memSqu++;
            }
            
            NSString *methodName = [self swiftMethod:method memberOffset:memberOffset member:record squ:j memSqu:memSqu fileData:fileData];
            uintptr_t imp = methodLocation + 4 + method.Offset;
            NSLog(@"%@.%@",className,methodName);
                
            [crashAddress enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                unsigned long long crash = [(NSString *)obj longLongValue];
                if ([self scanFuncBinaryCode:crash begin:imp vm:vm fileData:fileData]) {
                    NSString *key = [NSString stringWithFormat:@"%lld",crash];
                    if (!crashSymbolRst[key] || [crashSymbolRst[key][IMP_KEY] longLongValue] < imp) {
                        NSMutableDictionary *dic = @{IMP_KEY:@(imp),SYMBOL_KEY:[NSString stringWithFormat:@"%@.%@",className,methodName]}.mutableCopy;
                        [crashSymbolRst setObject:dic forKey:key];
                    }
                }
            }];
            methodLocation += sizeof(SwiftMethod);
        }
    }
    
    if((swiftType.Flag&0x40000000) == 0x40000000) {//有OverrideTable
        if ((swiftType.Flag&0x80000000) != 0x80000000) {//没有VTable
            methodLocation = typeOffset + sizeof(SwiftClassTypeNoMethods) + 4;
        }
        NSDictionary *overrideRst = [self scanSwiftClassOverrideMethodSymbol:methodLocation
                                                                   className:className
                                                                          vm:vm
                                                                    fileData:fileData
                                                                crashAdderss:crashAddress];
        [crashSymbolRst addEntriesFromDictionary:overrideRst];
    }
    
    return [crashSymbolRst copy];
}

+ (NSDictionary *)scanSwiftClassOverrideMethodSymbol:(uintptr_t)methodLocation
                                           className:(NSString*)className
                                                  vm:(uintptr_t)vm
                                            fileData:(NSData*)fileData
                                        crashAdderss:(NSArray *)crashAddress{
    NSMutableDictionary *crashSymbolRst = [NSMutableDictionary dictionary];
    
    UInt32 overrideNum = 0;
    NSRange range = NSMakeRange(methodLocation, 0);
    NSData *data = [WBBladesTool readBytes:range length:4 fromFile:fileData];
    [data getBytes:&overrideNum length:sizeof(4)];
    methodLocation +=4;
    
    for (NSInteger i = 0; i < overrideNum; i++) {
        SwiftOverrideMethod method = {0};
        range = NSMakeRange(methodLocation, 0);
        data = [WBBladesTool readBytes:range length:sizeof(SwiftOverrideMethod) fromFile:fileData];
        [data getBytes:&method length:sizeof(SwiftOverrideMethod)];
        
        uintptr_t overrideMethodOffset = methodLocation + 4 + method.OverrideMethod - vm;
        
        SwiftMethod overrideMethod = {0};
        range = NSMakeRange(overrideMethodOffset, 0);
        data = [WBBladesTool readBytes:range length:sizeof(SwiftMethod) fromFile:fileData];
        [data getBytes:&overrideMethod length:sizeof(SwiftMethod)];

        uintptr_t overrideClassOffset = methodLocation + method.OverrideClass - vm;
            
        SwiftType classType = {0};
        range = NSMakeRange(overrideClassOffset, 0);
        data = [WBBladesTool readBytes:range length:sizeof(SwiftType) fromFile:fileData];
        [data getBytes:&classType length:sizeof(SwiftType)];
        
        NSString *overrideClassName = [WBBladesTool getSwiftTypeNameWithSwiftType:classType Offset:overrideClassOffset fileData:fileData];

        NSString *methodName = [self swiftMethod:overrideMethod memberOffset:overrideMethodOffset member:{0} squ:0 memSqu:0 fileData:fileData];
        uintptr_t imp = overrideMethodOffset + 4 + overrideMethod.Offset;
        NSLog(@"%@重写%@.%@",className,overrideClassName,methodName);
        [crashAddress enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            unsigned long long crash = [(NSString *)obj longLongValue];
            if ([self scanFuncBinaryCode:crash begin:imp vm:vm fileData:fileData]) {
                NSString *key = [NSString stringWithFormat:@"%lld",crash];
                if (!crashSymbolRst[key] || [crashSymbolRst[key][IMP_KEY] longLongValue] < imp) {
                    NSMutableDictionary *dic = @{IMP_KEY:@(imp),SYMBOL_KEY:[NSString stringWithFormat:@"%@.%@",className,methodName]}.mutableCopy;
                    [crashSymbolRst setObject:dic forKey:key];
                }
            }
        }];
        
        methodLocation += sizeof(SwiftOverrideMethod);
    }
    
    return [crashSymbolRst copy];
}

+ (NSString *)swiftMethod:(SwiftMethod)method memberOffset:(uintptr_t)memberOffset member:(FieldRecord)member squ:(NSInteger)squ memSqu:(NSInteger)memSqu fileData:(NSData *)fileData{
    SwiftMethodKind kind = [WBBladesTool getSwiftMethodKind:method];
    SwiftMethodType type = [WBBladesTool getSwiftMethodType:method];
    
    NSString *methodName = @"";
    NSString *memName = @"";
    if (member.FieldName > 0 && (kind == SwiftMethodKindGetter || kind == SwiftMethodKindSetter || kind == SwiftMethodKindModify)) {
        uintptr_t memNameOffset = memberOffset + (memSqu-1)*sizeof(FieldRecord) + 4*2 + member.FieldName;
        uint8_t *buffer = (uint8_t *)malloc(CLASSNAME_MAX_LEN + 1); buffer[CLASSNAME_MAX_LEN] = '\0';
        [fileData getBytes:buffer range:NSMakeRange(memNameOffset, CLASSNAME_MAX_LEN)];
        memName = NSSTRING(buffer);
    }
    
    switch (kind) {
        case SwiftMethodKindMethod:
            if (type == SwiftMethodTypeKind) {
                methodName = [NSString stringWithFormat:@"第%lu个函数，他是一个类方法",squ-memSqu*3+1];
            }else if(type == SwiftMethodTypeInstance){
                methodName = [NSString stringWithFormat:@"第%lu个函数，他是一个实例方法",squ-memSqu*3+1];
            }else if(type == SwiftMethodTypeDynamic){
                methodName = [NSString stringWithFormat:@"第%lu个函数，他是一个dynamic方法",squ-memSqu*3+1];
            }
            break;
        case SwiftMethodKindInit:
            methodName = @"init";
            break;
        case SwiftMethodKindGetter:
            methodName = [NSString stringWithFormat:@"%@.getter",memName];
            break;
        case SwiftMethodKindSetter:
            methodName = [NSString stringWithFormat:@"%@.setter",memName];
            break;
        case SwiftMethodKindModify:
            methodName = [NSString stringWithFormat:@"%@.modify",memName];
            break;
        default:
            break;
    }
    return methodName;
}

#pragma mark Tools
+ (BOOL)hasDWARF:(symtab_command)symTabCommand fileData:(NSData *)fileData{
    BOOL has = YES;
    if (symTabCommand.nsyms > 0) {
        nlist_64 nlist;
        ptrdiff_t off = symTabCommand.symoff;
        char * p = (char *)fileData.bytes;
        p = p+off;
        memcpy(&nlist, p, sizeof(nlist_64));
        if (nlist.n_type == SPECIAL_SECTION_TYPE && nlist.n_sect == N_UNDF && nlist.n_value == SPECIAL_NUM) {
            has = NO;
        }
    }
    return has;
}
+ (NSDictionary *)scanExcutableSymbolTab:(NSData *)fileData range:(NSRange)range commandCount:(uint32_t)commandCount{
    range = [self rangeAlign:range];
    
    NSMutableDictionary *textSymbols = [NSMutableDictionary dictionary];
    for (int i = 0; i < commandCount; i++) {
        nlist_64 symbol = {0};
        NSData *symbolData = [WBBladesTool readBytes:range length:sizeof(nlist_64) fromFile:fileData];
        [symbolData getBytes:&symbol range:NSMakeRange(0, sizeof(nlist_64))];
        
        if (symbol.n_sect == 0x01) {//__TEXT,__text
            NSString *key = [NSString stringWithFormat:@"%llu",symbol.n_value];
            [textSymbols setValue:@(symbol.n_un.n_strx) forKey:key];
        }
    }

    return textSymbols;
}

@end
