//
//  EmojiScreenEffect.swift
//  Telegram
//
//  Created by Mikhail Filimonov on 14.09.2021.
//  Copyright © 2021 Telegram. All rights reserved.
//

import Foundation
import TGUIKit
import SwiftSignalKit
import TelegramCore
import Postbox

final class EmojiScreenEffect {
    fileprivate let context: AccountContext
    fileprivate let takeTableItem:(MessageId)->ChatRowItem?
    fileprivate(set) var scrollUpdater: TableScrollListener!
    private let dataDisposable: DisposableDict<MessageId> = DisposableDict()
    private let reactionDataDisposable: DisposableDict<MessageId> = DisposableDict()
    
    private let limit: Int = 5
    
    struct Key : Hashable {
        enum Mode : Equatable, Hashable {
            case effect
            case reaction(String)
        }
        let animationKey: LottieAnimationKey
        let messageId: MessageId
        let timestamp: TimeInterval
        let isIncoming: Bool
        let mode: Mode
        
        var screenMode: ChatRowView.ScreenEffectMode {
            switch self.mode {
            case let .reaction(value):
                return .reaction(value)
            case .effect:
                return .effect
            }
        }
    }
    
    struct Value {
        let view: WeakReference<EmojiAnimationEffectView>
        let index: Int
        let messageId: MessageId
        let emoji: String
        let mirror: Bool
        let key: Key
    }
    
    private var animations:[Key: Value] = [:]
    
    private var enqueuedToServer:[Value] = []
    private var enqueuedToEnjoy:[Value] = []
    
    private var enjoyTimer: SwiftSignalKit.Timer?

    private var timers:[MessageId : SwiftSignalKit.Timer] = [:]
    
    
    
    init(context: AccountContext, takeTableItem:@escaping(MessageId)->ChatRowItem?) {
        self.context = context
        self.takeTableItem = takeTableItem
        
        self.scrollUpdater = .init(dispatchWhenVisibleRangeUpdated: false, { [weak self] position in
            self?.updateScroll(transition: .immediate)
        })
    }
    
    private func checkItem(_ item: TableRowItem, _ messageId: MessageId, with emoji: String) -> Bool {
        if let item = item as? ChatRowItem, item.message?.text == emoji {
            if messageId.peerId.namespace == Namespaces.Peer.CloudUser {
                return context.sharedContext.baseSettings.bigEmoji
            }
        }
        return false
    }
    
    private func updateScroll(transition: ContainedViewLayoutTransition) {
        var outOfBounds: Set<Key> = Set()
        for (key, animation) in animations {
            var success: Bool = false
            if let animationView = animation.view.value {
                if let item = takeTableItem(key.messageId), let view = item.view as? ChatRowView {
                    if let contentView = view.getScreenEffectView(key.screenMode) {
                        var point = contentView.convert(CGPoint.zero, to: animationView)
                        let subSize = animationView.animationSize - contentView.frame.size
                        
                        switch key.mode {
                        case .effect:
                            if !item.isIncoming && item.renderType == .bubble {
                                point.x-=subSize.width
                            }
                            point.y-=subSize.height/2
                        case .reaction:
                            point.x-=subSize.width/2
                            point.y-=subSize.height/2
                        }
                       

                        
                        animationView.updatePoint(point, transition: transition)
                        
                        if contentView.visibleRect != .zero {
                            success = true
                        }
                    }
                }
            }
            if !success {
                outOfBounds.insert(key)
            }
        }
        for key in outOfBounds {
            self.deinitAnimation(key: key, animated: true)
        }
    }
    
    deinit {
        dataDisposable.dispose()
        reactionDataDisposable.dispose()
        let animations = self.animations
        for animation in animations {
            deinitAnimation(key: animation.key, animated: false)
        }
    }
    private func isLimitExceed(_ messageId: MessageId) -> Bool {
        let onair = animations.filter { $0.key.messageId == messageId }
        let last = onair.max(by: { $0.key.timestamp < $1.key.timestamp })
        if let last = last {
            if Date().timeIntervalSince1970 - last.key.timestamp < 0.2 {
                return true
            }
        }
        return onair.count >= limit
    }
    
    
    func addAnimation(_ emoji: String, index: Int?, mirror: Bool, isIncoming: Bool, messageId: MessageId, animationSize: NSSize, viewFrame: NSRect, for parentView: NSView) {
        
        if !isLimitExceed(messageId), let item = takeTableItem(messageId), checkItem(item, messageId, with: emoji) {
            let signal: Signal<LottieAnimation?, NoError> = context.diceCache.animationEffect(for: emoji.emojiUnmodified)
            |> map { value -> LottieAnimation? in
                if let random = value.randomElement(), let data = random.1 {
                    return LottieAnimation(compressed: data, key: .init(key: .bundle("_effect_\(emoji)"), size: animationSize, backingScale: Int(System.backingScale), mirror: mirror), cachePurpose: .temporaryLZ4(.effect), playPolicy: .onceEnd)
                } else {
                    return nil
                }
            }
            |> deliverOnMainQueue
            
            dataDisposable.set(signal.start(next: { [weak self, weak parentView] animation in
                if let animation = animation, let parentView = parentView {
                    self?.initAnimation(animation, mode: .effect, emoji: emoji, mirror: mirror, isIncoming: isIncoming, messageId: messageId, animationSize: animationSize, viewFrame: viewFrame, parentView: parentView)
                }
            }), forKey: messageId)
        } else {
            dataDisposable.set(nil, forKey: messageId)
        }
    }
    
    func addPremiumEffect(mirror: Bool, isIncoming: Bool, messageId: MessageId, viewFrame: NSRect, for parentView: NSView) {
        
        let context = self.context
        
        if !isLimitExceed(messageId), let item = takeTableItem(messageId) {
            let animationSize = NSMakeSize(item.contentSize.width * 2, item.contentSize.height * 2)
            let signal: Signal<(LottieAnimation, String)?, NoError> = context.account.postbox.messageAtId(messageId)
            |> mapToSignal { message in
                if let message = message, let file = message.media.first as? TelegramMediaFile {
                    if let effect = file.premiumEffect {
                        return context.account.postbox.mediaBox.resourceData(effect.resource) |> filter { $0.complete } |> take(1) |> map { data in
                            if data.complete, let data = try? Data(contentsOf: URL(fileURLWithPath: data.path)) {
                                return (LottieAnimation(compressed: data, key: .init(key: .bundle("_prem_effect_\(file.fileId.id)"), size: animationSize, backingScale: Int(System.backingScale), mirror: mirror), cachePurpose: .temporaryLZ4(.effect), playPolicy: .onceEnd), file.stickerText ?? "")
                            } else {
                                return nil
                            }
                        }
                    }
                }
                return .single(nil)
            }
            |> deliverOnMainQueue

            dataDisposable.set(signal.start(next: { [weak self, weak parentView] values in
                if let animation = values?.0, let emoji = values?.1, let parentView = parentView {
                    self?.initAnimation(animation, mode: .effect, emoji: emoji, mirror: mirror, isIncoming: isIncoming, messageId: messageId, animationSize: animationSize, viewFrame: viewFrame, parentView: parentView)
                }
            }), forKey: messageId)
        } else {
            dataDisposable.set(nil, forKey: messageId)
        }
    }
    
    func addReactionAnimation(_ value: String, index: Int?, messageId: MessageId, animationSize: NSSize, viewFrame: NSRect, for parentView: NSView) {
        
        let context = self.context
        
        let signal: Signal<LottieAnimation?, NoError> = context.reactions.stateValue |> take(1) |> map {
            return $0?.reactions.first(where: {
                $0.value == value
            })
        }
        |> filter { $0 != nil}
        |> map {
            $0!
        } |> mapToSignal { reaction -> Signal<MediaResourceData, NoError> in
            if let file = reaction.aroundAnimation {
                return context.account.postbox.mediaBox.resourceData(file.resource)
                |> filter { $0.complete }
                |> take(1)
            } else {
                return .complete()
            }
        } |> map { data in
            if let data = try? Data(contentsOf: URL(fileURLWithPath: data.path)) {
                return LottieAnimation(compressed: data, key: .init(key: .bundle("_reaction_e_\(value)"), size: animationSize, backingScale: Int(System.backingScale), mirror: false), cachePurpose: .temporaryLZ4(.effect), playPolicy: .onceEnd)
            } else {
                return nil
            }
        } |> deliverOnMainQueue
        
        reactionDataDisposable.set(signal.start(next: { [weak self, weak parentView] animation in
            if let animation = animation, let parentView = parentView {
                self?.initAnimation(animation, mode: .reaction(value), emoji: value, mirror: false, isIncoming: false, messageId: messageId, animationSize: animationSize, viewFrame: viewFrame, parentView: parentView)
            }
        }), forKey: messageId)
       
    }

    
    
    private func deinitAnimation(key: Key, animated: Bool) {
        let view = animations.removeValue(forKey: key)?.view.value
        if let view = view {
            performSubviewRemoval(view, animated: animated)
        }
        enqueuedToServer.removeAll(where: { $0.key == key })
        enqueuedToEnjoy.removeAll(where: { $0.key == key })
    }
    
    func removeAll() {
        let animations = self.animations
        for animation in animations {
            deinitAnimation(key: animation.key, animated: false)
        }
    }
    
    private func initAnimation(_ animation: LottieAnimation, mode: EmojiScreenEffect.Key.Mode, emoji: String, mirror: Bool, isIncoming: Bool, messageId: MessageId, animationSize: NSSize, viewFrame: NSRect, parentView: NSView) {
        
        
        let mediaView = (takeTableItem(messageId)?.view as? ChatMediaView)?.contentNode as? MediaAnimatedStickerView
        mediaView?.playAgain()
        
        let key: Key = .init(animationKey: animation.key.key, messageId: messageId, timestamp: Date().timeIntervalSince1970, isIncoming: isIncoming, mode: mode)
        
        animation.triggerOn = (LottiePlayerTriggerFrame.last, { [weak self] in
            self?.deinitAnimation(key: key, animated: true)
        }, {})
        
        let view = EmojiAnimationEffectView(animation: animation, animationSize: animationSize, animationPoint: .zero, frameRect: viewFrame)

        parentView.addSubview(view)
        
        let value: Value = .init(view: .init(value: view), index: 1, messageId: messageId, emoji: emoji, mirror: mirror, key: key)
        animations[key] = value
        
        updateScroll(transition: .immediate)
        if !isIncoming {
            self.enqueuedToServer.append(value)
        } else {
            self.enqueuedToEnjoy.append(value)
        }
        self.enqueueToServer()
        self.enqueueToEnjoy()
    }
    
    private func enqueueToEnjoy() {
        if enjoyTimer == nil, !enqueuedToEnjoy.isEmpty {
            enjoyTimer = .init(timeout: 1.0, repeat: false, completion: { [weak self] in
                self?.performEnjoyAction()
            }, queue: .mainQueue())
            enjoyTimer?.start()
        }
    }
    
    private func performEnjoyAction() {
        self.enjoyTimer = nil
        
        var exists:Set<MessageId> = Set()
        for value in enqueuedToEnjoy {
            if !exists.contains(value.key.messageId) {
                context.account.updateLocalInputActivity(peerId: PeerActivitySpace(peerId: value.key.messageId.peerId, category: .global), activity: .seeingEmojiInteraction(emoticon: value.emoji), isPresent: true)
                exists.insert(value.key.messageId)
            }
        }
        self.enqueuedToEnjoy.removeAll()
    }
    
    private func enqueueToServer() {
        let outgoing = self.enqueuedToServer
        let msgIds:[MessageId] = outgoing.map { $0.key.messageId }.uniqueElements
 
        for msgId in msgIds {
            if self.timers[msgId] == nil {
                self.timers[msgId] = .init(timeout: 1, repeat: false, completion: { [weak self] in
                    self?.performServerActions(for: msgId)
                }, queue: .mainQueue())
                self.timers[msgId]?.start()
            }
        }
    }
    
    private func performServerActions(for msgId: MessageId) {
        let values = self.enqueuedToServer.filter { $0.key.messageId == msgId }
        self.enqueuedToServer.removeAll(where: { $0.key.messageId == msgId })
        self.timers.removeValue(forKey: msgId)
        if !values.isEmpty {
            let value = values.min(by: { $0.key.timestamp < $1.key.timestamp })!
            let animations:[EmojiInteraction.Animation] = values.map { current -> EmojiInteraction.Animation in
                .init(index: current.index, timeOffset: Float((current.key.timestamp - value.key.timestamp)))
            }.sorted(by: { $0.timeOffset < $1.timeOffset })
            
            context.account.updateLocalInputActivity(peerId: PeerActivitySpace(peerId: msgId.peerId, category: .global), activity: .interactingWithEmoji(emoticon: value.emoji, messageId: msgId, interaction: EmojiInteraction(animations: animations)), isPresent: true)
        }
    }
    
    
    func updateLayout(rect: CGRect, transition: ContainedViewLayoutTransition) {
        for (_ , animation) in animations {
            if let value = animation.view.value {
                transition.updateFrame(view: value, frame: rect)
                value.updateLayout(size: rect.size, transition: transition)
            }
        }
    }
}
