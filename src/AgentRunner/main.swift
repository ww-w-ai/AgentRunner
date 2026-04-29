//
//  main.swift
//  AgentRunner
//
//  명시적 엔트리포인트. RunCat 패턴.
//  @main + storyboard 의존을 끊어 부트스트랩 안정화.
//  

import Cocoa

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
